//! microui 的 Android 渲染后端（SDL3 + SDL_ttf，手写绑定）
//!
//! 与桌面版 renderer.zig 的职责相同，替换掉 Windows GDI 字形方案：
//! - ASCII 走内置图集（atlas.zig）；
//! - 中文等 Unicode 字符用 SDL_ttf（FreeType）从内嵌字体栅格化到 512x512 动态纹理。
//!
//! 字体文件 font_simhei.ttf 编译期内嵌进 .so（@embedFile），免去 APK assets 访问。
//! 若要减小体积，可换成裁剪过的子集字体（如思源黑体子集）。
//! SDL 调用走 sdl3_android.zig 的手写绑定（Zig 0.16 无法为 Android 提供 cImport 所需 libc）。

const std = @import("std");
const microui = @import("microui");
const atlas = @import("atlas.zig");
const sdl = @import("sdl3_android");

const font_bytes = @embedFile("font_simhei.ttf");

// ===================== SDL 资源 =====================

var window: *sdl.SDL_Window = undefined;
var renderer: *sdl.SDL_Renderer = undefined;
var atlas_tex: *sdl.SDL_Texture = undefined;
var font: ?*sdl.TTF_Font = null;

// ===================== 动态中文字集（SDL_ttf 栅格化） =====================

const cjk_cell = 18; // 每个中文字形网格 18x18
const cjk_advance: i32 = 18; // 中文字符排版步进宽度
const cjk_tex_w = 512;
const cjk_tex_h = 512;
const cjk_cols = cjk_tex_w / cjk_cell; // 28
const cjk_cell_total = cjk_cols * (cjk_tex_h / cjk_cell); // 784

const Glyph = struct { cp: u32 = 0, x: i32 = 0, y: i32 = 0 };

var glyph_tex: *sdl.SDL_Texture = undefined;
var glyph_map: [cjk_cell_total]Glyph = undefined;
var glyph_map_len: usize = 0;
var glyph_cursor: usize = 0;
var glyph_zero: [cjk_tex_w * cjk_tex_h * 4]u8 = [_]u8{0} ** (cjk_tex_w * cjk_tex_h * 4);

/// 取码点对应的字形网格；缺失时用 SDL_ttf 栅格化并缓存。返回 null 表示失败（占位跳过）
fn glyphCell(cp: u32) ?Glyph {
    for (glyph_map[0..glyph_map_len]) |g| {
        if (g.cp == cp) return g;
    }
    const fnt = font orelse return null;
    if (cp > 0xFFFF) return null; // 暂不支持代理对（emoji 等）
    if (glyph_map_len >= cjk_cell_total) {
        // 网格用尽：清空缓存从头复用（演示足够）
        glyph_map_len = 0;
        glyph_cursor = 0;
    }

    // 渲染字形（白色，后面只取 alpha 通道，颜色由纹理调制）
    const surf = sdl.ttf_render_glyph_blended(fnt, cp, sdl.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 }) orelse {
        diagLog("glyph null cp={d} err={s}", .{ cp, sdl.errorString() });
        return null;
    };
    defer sdl.destroySurface(surf);

    // 分配网格，把字形 alpha 拷进白色 RGBA 网格：水平居中、底部对齐
    const col = glyph_cursor % cjk_cols;
    const row = glyph_cursor / cjk_cols;
    const cx: i32 = @intCast(col * cjk_cell);
    const cy: i32 = @intCast(row * cjk_cell);
    glyph_cursor += 1;

    const dst_x = @divTrunc(cjk_cell - @as(i32, surf.w), 2);
    const dst_y = cjk_cell - @as(i32, surf.h);
    var pixels = [_]u8{0} ** (cjk_cell * cjk_cell * 4);
    const src: [*]const u8 = @ptrCast(surf.pixels);
    var yy: i32 = 0;
    while (yy < surf.h) : (yy += 1) {
        var xx: i32 = 0;
        while (xx < surf.w) : (xx += 1) {
            // SDL_ttf 输出 ARGB8888，小端内存序 B,G,R,A → alpha 在字节 3
            const a = src[@as(usize, @intCast(yy)) * @as(usize, @intCast(surf.pitch)) + @as(usize, @intCast(xx)) * 4 + 3];
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
    if (!sdl.updateTexture(glyph_tex, &cell_rect, &pixels, cjk_cell * 4)) {
        diagLog("glyph update fail cp={d} err={s}", .{ cp, sdl.errorString() });
    }

    const g = Glyph{ .cp = cp, .x = cx, .y = cy };
    glyph_map[glyph_map_len] = g;
    glyph_map_len += 1;
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
    return sdl.errorString();
}

/// 格式化并写 logcat（诊断用，tag = ZigDemo）
fn diagLog(comptime fmt: []const u8, args: anytype) void {
    var buf: [192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    sdl.logMsg(s);
}

// ===================== 公开接口 =====================

/// 初始化后端：SDL + 窗口 + 渲染器 + 图集 + SDL_ttf 字体 + 动态字形纹理。
/// 在 Android 上由 SDLActivity 先初始化 SDL 环境，SDL_main 内直接创建窗口。
pub fn init() void {
    if (!sdl.init(sdl.SDL_INIT_VIDEO)) {
        fail("SDL_Init failed: {s}", .{sdlErr()});
    }

    // 尺寸传 0：Android 上窗口由系统表面决定（全屏）
    var win: ?*sdl.SDL_Window = null;
    var rr: ?*sdl.SDL_Renderer = null;
    if (!sdl.createWindowAndRenderer("microui", 0, 0, 0, &win, &rr)) {
        fail("SDL_CreateWindowAndRenderer failed: {s}", .{sdlErr()});
    }
    window = win.?;
    renderer = rr.?;
    // 开启文本输入：Android 上会唤起系统输入法（IME），输入框才能打字
    _ = sdl.startTextInput(window);

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
    // SDL_PIXELFORMAT_RGBA32（小端 = ABGR8888）的内存字节序为 R,G,B,A，与上传数据一致。
    atlas_tex = sdl.createTexture(renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_STATIC, atlas.W, atlas.H) orelse
        fail("SDL_CreateTexture failed: {s}", .{sdlErr()});
    if (!sdl.updateTexture(atlas_tex, null, &rgba, atlas.W * 4)) {
        fail("SDL_UpdateTexture failed: {s}", .{sdlErr()});
    }
    _ = sdl.setTextureBlendMode(atlas_tex, sdl.SDL_BLENDMODE_BLEND);

    // 动态中文字集：SDL_ttf + 512x512 透明纹理（STREAMING：渲染中按需更新）
    if (!sdl.ttf_init()) {
        fail("TTF_Init failed: {s}", .{sdlErr()});
    }
    const io = sdl.ioFromConstMem(font_bytes, font_bytes.len); // @embedFile 返回的即指针
    font = sdl.ttf_open_font_io(io.?, true, 18.0);
    if (font == null) {
        fail("TTF_OpenFontIO failed: {s}", .{sdlErr()});
    }
    diagLog("TTF font ok, bytes={d}", .{font_bytes.len});
    glyph_tex = sdl.createTexture(renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_STREAMING, cjk_tex_w, cjk_tex_h) orelse
        fail("创建字形纹理失败: {s}", .{sdlErr()});
    if (!sdl.updateTexture(glyph_tex, null, &glyph_zero, cjk_tex_w * 4)) {
        fail("字形纹理上传失败: {s}", .{sdlErr()});
    }
    _ = sdl.setTextureBlendMode(glyph_tex, sdl.SDL_BLENDMODE_BLEND);
    diagLog("glyph tex ok, renderer ready", .{});
}

/// 释放全部资源
pub fn deinit() void {
    if (font) |f| sdl.ttf_close_font(f);
    sdl.ttf_quit();
    sdl.destroyTexture(atlas_tex);
    sdl.destroyTexture(glyph_tex);
    sdl.destroyRenderer(renderer);
    sdl.destroyWindow(window);
    sdl.quit();
}

/// 清屏：用给定颜色填充整个画面
pub fn begin(color: microui.Color) void {
    _ = sdl.setRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
    _ = sdl.renderClear(renderer);
}

/// 提交本帧画面
pub fn end() void {
    _ = sdl.renderPresent(renderer);
}

/// 当前窗口像素尺寸（触摸归一化坐标换算用）
pub fn windowSize() [2]c_int {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = sdl.getWindowSize(window, &w, &h);
    return .{ w, h };
}

/// 确保文本输入已开启。Android 上 init 时调用可能因窗口尚未聚焦而失效，
/// 每帧兜底调用一次（SDL 内部幂等：text_input_active 已激活则不再弹输入法）
pub fn ensureTextInput() void {
    _ = sdl.startTextInput(window);
}

/// 设置裁剪区域（库用超大矩形表示"不裁剪"，此时直接关闭 SDL 裁剪）
pub fn setClipRect(rect: microui.Rect) void {
    if (rect.w >= 0x1000000 or rect.h >= 0x1000000) {
        _ = sdl.setRenderClipRect(renderer, null);
    } else {
        var r = sdl.SDL_Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
        _ = sdl.setRenderClipRect(renderer, &r);
    }
}

/// 填充矩形
pub fn drawRect(rect: microui.Rect, color: microui.Color) void {
    _ = sdl.setRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
    var fr = sdl.SDL_FRect{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
    };
    _ = sdl.renderFillRect(renderer, &fr);
}

/// 绘制文本：ASCII 走内置图集，Unicode 走动态中文字集
pub fn drawText(str: []const u8, pos: microui.Vec2, color: microui.Color) void {
    // 两套纹理都设好颜色调制：ASCII 走原图集，Unicode 走动态字形纹理
    _ = sdl.setTextureColorMod(atlas_tex, color.r, color.g, color.b);
    _ = sdl.setTextureAlphaMod(atlas_tex, color.a);
    _ = sdl.setTextureColorMod(glyph_tex, color.r, color.g, color.b);
    _ = sdl.setTextureAlphaMod(glyph_tex, color.a);

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
            if (!sdl.renderTexture(renderer, atlas_tex, &src, &dst)) {
                if (std.debug.runtime_safety) std.debug.print("RenderTexture 失败: {s}\n", .{sdlErr()});
                return;
            }
            dst_x += dst.w;
        } else if ((ch & 0xc0) == 0x80) {
            i += 1; // 孤立续字节，跳过
        } else {
            // Unicode：解码码点，动态生成/复用字形
            const cp = decodeUtf8(str, &i);
            if (glyphCell(cp)) |g| {
                const src = sdl.SDL_FRect{
                    .x = @floatFromInt(g.x),
                    .y = @floatFromInt(g.y),
                    .w = cjk_cell,
                    .h = cjk_cell,
                };
                var dst = sdl.SDL_FRect{ .x = dst_x, .y = dst_y, .w = cjk_advance, .h = 18 };
                if (!sdl.renderTexture(renderer, glyph_tex, &src, &dst)) {
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
    _ = sdl.setTextureColorMod(atlas_tex, color.r, color.g, color.b);
    _ = sdl.setTextureAlphaMod(atlas_tex, color.a);
    _ = sdl.renderTexture(renderer, atlas_tex, &src, &dst);
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
