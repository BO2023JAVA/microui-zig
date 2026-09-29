//! microui 的 SDL3 渲染后端（Backend）
//!
//! 职责：
//! 1. 实现 microui 需要的两个测量回调（text_width / text_height）；
//! 2. 把 microui 生成的绘制命令列表（矩形/文字/图标/裁剪）翻译成 SDL3 Render API 调用；
//! 3. 负责"字"这件事：ASCII 走内置图集，中文等 Unicode 字符用 Windows GDI
//!    从系统字体（微软雅黑/宋体）实时栅格化到一张 512x512 动态纹理。
//!
//! 使用方式：
//!   renderer.init() → 每帧 renderer.begin(背景色) → renderer.render(ctx) → renderer.end()
//!   ctx.text_width = renderer.textWidth; ctx.text_height = renderer.textHeight;
//!
//! 本文件与 SDL/Windows 强绑定；换成 OpenGL/软件渲染只需另写一个同接口的后端。

const std = @import("std");
const sdl = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL3/SDL.h");
});
const microui = @import("microui");
const atlas = @import("atlas.zig");

// ===================== SDL 资源 =====================

var window: *sdl.SDL_Window = undefined;
var renderer: *sdl.SDL_Renderer = undefined;
var atlas_tex: *sdl.SDL_Texture = undefined;

// ===================== 中文动态字集（Windows GDI 栅格化） =====================
// 图集只含 ASCII 字形；中文等 Unicode 字符在运行时用系统字体栅格化进一张
// 512x512 动态纹理，按"码点 → 网格"缓存，首次出现时生成、之后直接复用。

const default_charset: u32 = 1;
const out_tt_precis: u32 = 4;
const clip_default_precis: u32 = 0;
const antialiased_quality: u32 = 4;
const default_pitch: u32 = 0;
const ff_dontcare: u32 = 0;
const transparent_bk: i32 = 1; // 透明背景（TextOut 只画字形）
const bi_rgb: u32 = 0;

const BITMAPINFOHEADER = extern struct {
    biSize: u32 = 40,
    biWidth: i32 = 0,
    biHeight: i32 = 0,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = bi_rgb,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};
const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER = .{},
    bmiColors: [1]u32 = .{0},
};

extern "c" fn CreateCompatibleDC(hdc: ?*anyopaque) ?*anyopaque;
extern "c" fn CreateFontW(
    cHeight: i32,
    cWidth: i32,
    cEscapement: i32,
    cOrientation: i32,
    cWeight: i32,
    bItalic: u32,
    bUnderline: u32,
    bStrikeOut: u32,
    iCharSet: u32,
    iOutPrecision: u32,
    iClipPrecision: u32,
    iQuality: u32,
    iPitchAndFamily: u32,
    pszFaceName: [*:0]const u16,
) ?*anyopaque;
extern "c" fn SelectObject(hdc: ?*anyopaque, h: ?*anyopaque) ?*anyopaque;
extern "c" fn DeleteObject(h: ?*anyopaque) i32;
extern "c" fn DeleteDC(hdc: ?*anyopaque) i32;
extern "c" fn CreateDIBSection(
    hdc: ?*anyopaque,
    pbmi: *const BITMAPINFO,
    usage: u32,
    ppvBits: ?*?*anyopaque,
    hSection: ?*anyopaque,
    offset: u32,
) ?*anyopaque;
extern "c" fn SetBkMode(hdc: ?*anyopaque, mode: i32) i32;
extern "c" fn SetTextColor(hdc: ?*anyopaque, color: u32) u32;
extern "c" fn TextOutW(hdc: ?*anyopaque, x: i32, y: i32, str: [*]const u16, len: i32) i32;
extern "c" fn SDL_SetMainReady() void;

const cjk_cell = 18; // 每个中文字形网格 18x18
const cjk_advance: i32 = 18; // 中文字符排版步进宽度
const cjk_tex_w = 512;
const cjk_tex_h = 512;
const cjk_cols = cjk_tex_w / cjk_cell; // 28
const cjk_cell_total = cjk_cols * (cjk_tex_h / cjk_cell); // 784
const gdi_bit_w = 32; // GDI 临时位图尺寸（容纳单个字形）
const gdi_bit_h = 32;

const CjkGlyph = struct { cp: u32 = 0, x: i32 = 0, y: i32 = 0 };

var cjk_tex: *sdl.SDL_Texture = undefined;
var cjk_map: [cjk_cell_total]CjkGlyph = undefined;
var cjk_map_len: usize = 0;
var cjk_cursor: usize = 0;
var gdi_dc: ?*anyopaque = null;
var gdi_font: ?*anyopaque = null;
var gdi_bmp: ?*anyopaque = null;
var gdi_bits: ?*anyopaque = null;
var cjk_zero: [cjk_tex_w * cjk_tex_h * 4]u8 = [_]u8{0} ** (cjk_tex_w * cjk_tex_h * 4);

/// 初始化 GDI：字体 + 32x32 临时位图（TextOut 渲染字形后读回像素）
fn gdiInit() void {
    gdi_dc = CreateCompatibleDC(null);
    if (gdi_dc == null) return;
    const yahei = std.unicode.utf8ToUtf16LeStringLiteral("Microsoft YaHei");
    const simsun = std.unicode.utf8ToUtf16LeStringLiteral("SimSun");
    var font = CreateFontW(
        -17,
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        default_charset,
        out_tt_precis,
        clip_default_precis,
        antialiased_quality,
        default_pitch | ff_dontcare,
        yahei,
    );
    if (font == null) {
        font = CreateFontW(
            -17,
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            default_charset,
            out_tt_precis,
            clip_default_precis,
            antialiased_quality,
            default_pitch | ff_dontcare,
            simsun,
        );
    }
    if (font == null) return;
    gdi_font = font;
    _ = SelectObject(gdi_dc, font);

    // 32x32 32bpp 位图，负高度 = 自上而下的行序
    var bmi = BITMAPINFO{ .bmiHeader = .{ .biWidth = gdi_bit_w, .biHeight = -gdi_bit_h } };
    var bits: ?*anyopaque = null;
    const bmp = CreateDIBSection(gdi_dc, &bmi, 0, &bits, null, 0);
    if (bmp == null or bits == null) return;
    gdi_bmp = bmp;
    gdi_bits = bits;
    _ = SelectObject(gdi_dc, bmp);
    _ = SetBkMode(gdi_dc, transparent_bk);
    _ = SetTextColor(gdi_dc, 0x00FFFFFF); // 白色字形（黑底上读 alpha）
}

/// 取码点对应的字形网格；缺失时栅格化并缓存。返回 null 表示失败（渲染时占位跳过）
fn cjkCell(cp: u32) ?CjkGlyph {
    for (cjk_map[0..cjk_map_len]) |g| {
        if (g.cp == cp) return g;
    }
    if (gdi_dc == null or gdi_bits == null) return null;
    if (cp > 0xFFFF) return null; // 暂不支持代理对（emoji 等）
    if (cjk_map_len >= cjk_cell_total) {
        // 网格用尽：清空缓存从头复用（演示足够）
        cjk_map_len = 0;
        cjk_cursor = 0;
    }

    // 用 TextOut 把字形画进临时位图（白字黑底），再读回像素
    const pix: [*]u8 = @ptrCast(gdi_bits);
    @memset(pix[0 .. gdi_bit_w * gdi_bit_h * 4], 0);
    var wch: [1]u16 = undefined;
    wch[0] = @intCast(cp);
    _ = TextOutW(gdi_dc, 0, 0, &wch, 1);

    // 求字形包围盒 + 提取 alpha（B 通道即亮度）
    var min_x: i32 = gdi_bit_w;
    var min_y: i32 = gdi_bit_h;
    var max_x: i32 = -1;
    var max_y: i32 = -1;
    var y: i32 = 0;
    while (y < gdi_bit_h) : (y += 1) {
        var x: i32 = 0;
        while (x < gdi_bit_w) : (x += 1) {
            const idx = @as(usize, @intCast((y * gdi_bit_w + x) * 4));
            if (pix[idx + 2] > 0) { // B 通道：白字黑底
                if (x < min_x) min_x = x;
                if (x > max_x) max_x = x;
                if (y < min_y) min_y = y;
                if (y > max_y) max_y = y;
            }
        }
    }
    if (max_x < 0) return null; // 空白字符（如空格）不入图集

    const bw = max_x - min_x + 1;
    const bh = max_y - min_y + 1;

    // 分配网格，把字形拷进白色 RGBA 网格：水平居中、底部对齐
    const col = cjk_cursor % cjk_cols;
    const row = cjk_cursor / cjk_cols;
    const cx: i32 = @intCast(col * cjk_cell);
    const cy: i32 = @intCast(row * cjk_cell);
    cjk_cursor += 1;

    const dst_x = @divTrunc(cjk_cell - bw, 2);
    const dst_y = cjk_cell - bh;
    var pixels = [_]u8{0} ** (cjk_cell * cjk_cell * 4);
    var yy: i32 = 0;
    while (yy < bh) : (yy += 1) {
        var xx: i32 = 0;
        while (xx < bw) : (xx += 1) {
            const a = pix[@as(usize, @intCast(((min_y + yy) * gdi_bit_w + (min_x + xx)) * 4 + 2))];
            const px = dst_x + xx;
            const py = dst_y + yy;
            if (px >= 0 and px < cjk_cell and py >= 0 and py < cjk_cell) {
                const idx = @as(usize, @intCast(py * cjk_cell + px)) * 4;
                pixels[idx + 0] = 255;
                pixels[idx + 1] = 255;
                pixels[idx + 2] = 255;
                pixels[idx + 3] = a;
            }
        }
    }
    var cell_rect = sdl.SDL_Rect{ .x = cx, .y = cy, .w = cjk_cell, .h = cjk_cell };
    _ = sdl.SDL_UpdateTexture(cjk_tex, &cell_rect, &pixels, cjk_cell * 4);

    const g = CjkGlyph{ .cp = cp, .x = cx, .y = cy };
    cjk_map[cjk_map_len] = g;
    cjk_map_len += 1;
    return g;
}

/// 解码一个 UTF-8 码点并推进索引（非法字节按单字节处理）
fn decodeUtf8(s: []const u8, i: *usize) u32 {
    const b0 = s[i.*];
    var cp: u32 = b0;
    var len: usize = 1;
    if (b0 >= 0xF0) {
        cp = b0 & 0x07;
        len = 4;
    } else if (b0 >= 0xE0) {
        cp = b0 & 0x0F;
        len = 3;
    } else if (b0 >= 0xC0) {
        cp = b0 & 0x1F;
        len = 2;
    } else if (b0 >= 0x80) {
        i.* += 1;
        return cp; // 孤立续字节
    }
    if (i.* + len > s.len) {
        i.* += 1;
        return cp;
    }
    var k: usize = 1;
    while (k < len) : (k += 1) {
        const b = s[i.* + k];
        if ((b & 0xc0) != 0x80) {
            i.* += 1;
            return cp;
        }
        cp = (cp << 6) | (b & 0x3f);
    }
    i.* += len;
    return cp;
}

/// 致命错误：Debug 构建打印原因后退出，发布构建直接退出（避免拖入格式化代码）
fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    if (std.debug.runtime_safety) {
        std.debug.print(fmt ++ "\n", args);
    }
    std.process.exit(1);
}

fn sdlErr() []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(sdl.SDL_GetError())));
}

// ===================== 公开接口 =====================

/// 初始化后端：SDL + 窗口 + 渲染器 + 图集纹理 + GDI 中文字集。
/// 内部完成 SDL_SetMainReady / SDL_Init(SDL_INIT_VIDEO)，并开启文本输入（输入框可打字）。
pub fn init() void {
    SDL_SetMainReady();
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
        fail("SDL_Init failed: {s}", .{sdlErr()});
    }

    var win: ?*sdl.SDL_Window = null;
    var rr: ?*sdl.SDL_Renderer = null;
    if (!sdl.SDL_CreateWindowAndRenderer("microui", 800, 600, sdl.SDL_WINDOW_RESIZABLE, &win, &rr)) {
        fail("SDL_CreateWindowAndRenderer failed: {s}", .{sdlErr()});
    }
    window = win.?;
    renderer = rr.?;
    // 开启文本输入：SDL 默认不派发文本输入事件，不开启则输入框无法打字
    _ = sdl.SDL_StartTextInput(window);

    // 把 128x128 的 alpha 位图打包成 RGBA
    var rgba: [atlas.W * atlas.H * 4]u8 = undefined;
    for (atlas.texture, 0..) |a, i| {
        rgba[i * 4 + 0] = 0xff;
        rgba[i * 4 + 1] = 0xff;
        rgba[i * 4 + 2] = 0xff;
        rgba[i * 4 + 3] = a;
    }
    // 注意：RGBA8888 在小端机器上的内存字节序是 A,B,G,R（见 SDL_pixels.h 的别名表），
    // 直接按 [R,G,B,A] 上传会错位导致文字出现彩色底块。
    // SDL_PIXELFORMAT_RGBA32 的内存字节序恒为 R,G,B,A，与上传数据一致。
    const tex_created: [*c]sdl.SDL_Texture = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_STATIC, atlas.W, atlas.H);
    if (tex_created == null) {
        fail("SDL_CreateTexture failed: {s}", .{sdlErr()});
    }
    atlas_tex = tex_created;
    if (!sdl.SDL_UpdateTexture(atlas_tex, null, &rgba, atlas.W * 4)) {
        fail("SDL_UpdateTexture failed: {s}", .{sdlErr()});
    }
    _ = sdl.SDL_SetTextureBlendMode(atlas_tex, sdl.SDL_BLENDMODE_BLEND);

    // 中文动态字集：GDI 字体 + 512x512 透明纹理（STREAMING：渲染中按需更新）
    gdiInit();
    const cjk_created: [*c]sdl.SDL_Texture = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_STREAMING, cjk_tex_w, cjk_tex_h);
    if (cjk_created == null) {
        fail("创建中文字集纹理失败: {s}", .{sdlErr()});
    }
    cjk_tex = cjk_created;
    if (!sdl.SDL_UpdateTexture(cjk_tex, null, &cjk_zero, cjk_tex_w * 4)) {
        fail("中文字集纹理上传失败: {s}", .{sdlErr()});
    }
    _ = sdl.SDL_SetTextureBlendMode(cjk_tex, sdl.SDL_BLENDMODE_BLEND);
}

/// 释放全部资源（SDL 资源 + GDI 对象）
pub fn deinit() void {
    // init 失败时会直接退出，能走到这里说明四个 SDL 资源必然已创建
    sdl.SDL_DestroyTexture(atlas_tex);
    sdl.SDL_DestroyTexture(cjk_tex);
    sdl.SDL_DestroyRenderer(renderer);
    sdl.SDL_DestroyWindow(window);
    // GDI 顺序：先删 DC，再删被选中过的对象
    if (gdi_dc) |dc| _ = DeleteDC(dc);
    if (gdi_bmp) |b| _ = DeleteObject(b);
    if (gdi_font) |f| _ = DeleteObject(f);
    sdl.SDL_Quit();
}

/// 清屏：用给定颜色填充整个画面
pub fn begin(color: microui.Color) void {
    _ = sdl.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
    _ = sdl.SDL_RenderClear(renderer);
}

/// 提交本帧画面
pub fn end() void {
    _ = sdl.SDL_RenderPresent(renderer);
}

/// 设置裁剪区域（库用超大矩形表示"不裁剪"，此时直接关闭 SDL 裁剪）
pub fn setClipRect(rect: microui.Rect) void {
    if (rect.w >= 0x1000000 or rect.h >= 0x1000000) {
        _ = sdl.SDL_SetRenderClipRect(renderer, null);
    } else {
        var r = sdl.SDL_Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
        _ = sdl.SDL_SetRenderClipRect(renderer, &r);
    }
}

/// 填充矩形
pub fn drawRect(rect: microui.Rect, color: microui.Color) void {
    _ = sdl.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
    var fr = sdl.SDL_FRect{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
    };
    _ = sdl.SDL_RenderFillRect(renderer, &fr);
}

/// 绘制文本：ASCII 走内置图集，Unicode 走动态中文字集
pub fn drawText(str: []const u8, pos: microui.Vec2, color: microui.Color) void {
    // 两套纹理都设好颜色调制：ASCII 走原图集，Unicode 走动态中文字集
    _ = sdl.SDL_SetTextureColorMod(atlas_tex, color.r, color.g, color.b);
    _ = sdl.SDL_SetTextureAlphaMod(atlas_tex, color.a);
    _ = sdl.SDL_SetTextureColorMod(cjk_tex, color.r, color.g, color.b);
    _ = sdl.SDL_SetTextureAlphaMod(cjk_tex, color.a);

    var i: usize = 0;
    const dst_y: f32 = @floatFromInt(pos.y);
    var dst_x: f32 = @floatFromInt(pos.x);
    while (i < str.len) {
        const ch = str[i];
        if (ch < 0x80) {
            // ASCII
            i += 1;
            if (ch < 32) continue;
            const g = atlas.glyphs[ch - 32];
            const src = sdl.SDL_FRect{
                .x = @floatFromInt(g.x),
                .y = @floatFromInt(g.y),
                .w = @floatFromInt(g.w),
                .h = @floatFromInt(g.h),
            };
            var dst = sdl.SDL_FRect{ .x = dst_x, .y = dst_y, .w = @floatFromInt(g.w), .h = 18 };
            if (!sdl.SDL_RenderTexture(renderer, atlas_tex, &src, &dst)) {
                if (std.debug.runtime_safety) std.debug.print("RenderTexture 失败: {s}\n", .{sdlErr()});
                return;
            }
            dst_x += dst.w;
        } else if ((ch & 0xc0) == 0x80) {
            i += 1; // 孤立续字节，跳过
        } else {
            // Unicode：解码码点，动态生成/复用字形
            const cp = decodeUtf8(str, &i);
            if (cjkCell(cp)) |g| {
                const src = sdl.SDL_FRect{
                    .x = @floatFromInt(g.x),
                    .y = @floatFromInt(g.y),
                    .w = cjk_cell,
                    .h = cjk_cell,
                };
                var dst = sdl.SDL_FRect{ .x = dst_x, .y = dst_y, .w = cjk_advance, .h = 18 };
                if (!sdl.SDL_RenderTexture(renderer, cjk_tex, &src, &dst)) {
                    if (std.debug.runtime_safety) std.debug.print("RenderTexture 失败: {s}\n", .{sdlErr()});
                    return;
                }
                dst_x += dst.w;
            } else {
                dst_x += cjk_advance; // 无字形也占位，保持对齐
            }
        }
    }
}

/// 绘制图标（居中对齐到 rect 内）
pub fn drawIcon(id: u32, rect: microui.Rect, color: microui.Color) void {
    if (id < 1 or id > atlas.icons.len) return;
    const g = atlas.icons[id - 1];
    const src = sdl.SDL_FRect{
        .x = @floatFromInt(g.x),
        .y = @floatFromInt(g.y),
        .w = @floatFromInt(g.w),
        .h = @floatFromInt(g.h),
    };
    const x = rect.x + @divTrunc(rect.w - g.w, 2);
    const y = rect.y + @divTrunc(rect.h - g.h, 2);
    var dst = sdl.SDL_FRect{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .w = @floatFromInt(g.w),
        .h = @floatFromInt(g.h),
    };
    _ = sdl.SDL_SetTextureColorMod(atlas_tex, color.r, color.g, color.b);
    _ = sdl.SDL_SetTextureAlphaMod(atlas_tex, color.a);
    _ = sdl.SDL_RenderTexture(renderer, atlas_tex, &src, &dst);
}

/// 渲染一整帧：遍历 microui 的命令列表并逐条绘制（在 begin/end 之间调用）
pub fn render(ctx: *microui.Context) void {
    var it = ctx.commandIter();
    while (it.next()) |cmd| {
        switch (cmd) {
            .text => |t| drawText(t.str[0..t.len], t.pos, t.color),
            .rect => |r| drawRect(r.rect, r.color),
            .icon => |ic| drawIcon(ic.id, ic.rect, ic.color),
            .clip => |rc| setClipRect(rc),
            else => {},
        }
    }
}

/// microui 文本宽度回调：ASCII 用图集字形宽度，Unicode 用固定步进
pub fn textWidth(ctx: *microui.Context, str: []const u8) i32 {
    _ = ctx;
    var res: i32 = 0;
    var i: usize = 0;
    while (i < str.len) {
        const ch = str[i];
        if (ch < 0x80) {
            i += 1;
            if (ch >= 32) res += atlas.glyphs[ch - 32].w;
        } else if ((ch & 0xc0) == 0x80) {
            i += 1; // 孤立续字节
        } else {
            _ = decodeUtf8(str, &i);
            res += cjk_advance;
        }
    }
    return res;
}

/// microui 文本高度回调
pub fn textHeight(ctx: *microui.Context) i32 {
    _ = ctx;
    return 18;
}
