//! microui —— 极简即时模式 UI 库（Zig 重写版）
//!
//! 设计要点：
//! - 无堆分配：所有状态都用固定容量数组，宿主无需提供分配器；
//! - 即时模式：每帧调用控件函数重建界面，跨帧状态靠 ID + 对象池保留；
//! - 前后端分离：本库只生成"绘制命令列表"，真正的渲染由宿主完成；
//! - 宿主只需实现 text_width / text_height 两个测量回调，
//!   在 mu.end() 之后遍历命令列表即可绘制。

const std = @import("std");

// ===================== 常量 =====================

pub const root_list_cap = 32;          // 根容器列表容量
pub const container_stack_cap = 32;    // 容器嵌套栈容量
pub const clip_stack_cap = 32;         // 裁剪矩形栈容量
pub const id_stack_cap = 32;           // ID 栈容量
pub const layout_stack_cap = 16;       // 布局栈容量
pub const container_pool_cap = 48;     // 容器对象池大小
pub const treenode_pool_cap = 48;      // 树节点对象池大小
pub const max_widths = 16;             // 一行最多列数
pub const command_cap = 1024;          // 绘制命令容量
pub const text_cap = 128;              // 单条文本命令的最大字符数
pub const max_fmt = 64;                // 数字编辑缓冲区大小

pub const Real = f32;                  // 数字控件浮点类型

// ===================== 基本类型 =====================

pub const Vec2 = struct { x: i32 = 0, y: i32 = 0 };

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn init(x: i32, y: i32, w: i32, h: i32) Rect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }
};

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

    pub fn init(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

pub const Id = u32;

/// 颜色 ID（索引 Style.colors）
pub const color_count = 14;
pub const ColorId = enum(u8) {
    text,
    border,
    window_bg,
    title_bg,
    title_text,
    panel_bg,
    button,
    button_hover,
    button_focus,
    base,
    base_hover,
    base_focus,
    scroll_base,
    scroll_thumb,
};

/// 图标 ID（对应图集中的图标）
pub const Icon = enum(u8) {
    close = 1,
    check,
    expanded,
    collapsed,
};

// 控件返回值标志
pub const res_active: u8 = 1 << 0; // 激活/展开
pub const res_submit: u8 = 1 << 1; // 提交（按钮点击、回车）
pub const res_change: u8 = 1 << 2; // 数值变化

// 控件/窗口选项标志
pub const opt_align_center: u16 = 1 << 0;
pub const opt_align_right: u16 = 1 << 1;
pub const opt_no_interact: u16 = 1 << 2;
pub const opt_no_frame: u16 = 1 << 3;
pub const opt_no_resize: u16 = 1 << 4;
pub const opt_no_scroll: u16 = 1 << 5;
pub const opt_no_close: u16 = 1 << 6;
pub const opt_no_title: u16 = 1 << 7;
pub const opt_hold_focus: u16 = 1 << 8;
pub const opt_auto_size: u16 = 1 << 9;
pub const opt_popup: u16 = 1 << 10;
pub const opt_closed: u16 = 1 << 11;
pub const opt_expanded: u16 = 1 << 12;

// 鼠标按键标志
pub const mouse_left: u8 = 1 << 0;
pub const mouse_right: u8 = 1 << 1;
pub const mouse_middle: u8 = 1 << 2;

// 键盘按键标志
pub const key_shift: u8 = 1 << 0;
pub const key_ctrl: u8 = 1 << 1;
pub const key_alt: u8 = 1 << 2;
pub const key_backspace: u8 = 1 << 3;
pub const key_return: u8 = 1 << 4;

// 裁剪检测结果
pub const clip_part = 1;
pub const clip_all = 2;

/// 默认"不裁剪"矩形（尺寸极大，任何矩形与它求交集都等于自身）
const unclipped_rect = Rect{ .w = 0x1000000, .h = 0x1000000 };

// ===================== 数据结构 =====================

/// 定长栈
pub fn Stack(comptime T: type, comptime n: usize) type {
    return struct {
        items: [n]T = undefined,
        len: usize = 0,

        pub fn push(self: *@This(), v: T) void {
            std.debug.assert(self.len < n);
            self.items[self.len] = v;
            self.len += 1;
        }

        pub fn pop(self: *@This()) void {
            std.debug.assert(self.len > 0);
            self.len -= 1;
        }

        pub fn top(self: *const @This()) *const T {
            return &self.items[self.len - 1];
        }

        pub fn topMut(self: *@This()) *T {
            return &self.items[self.len - 1];
        }
    };
}

/// 对象池条目：id + 最近更新帧号
pub const PoolItem = struct { id: Id = 0, last_update: u32 = 0 };

/// 布局状态
pub const Layout = struct {
    body: Rect = .{},          // 布局主体区域（已减滚动偏移）
    next: Rect = .{},          // 由 layoutSetNext 指定的矩形
    position: Vec2 = .{},      // 当前控件起点（相对 body）
    size: Vec2 = .{},          // 行高 / 单列宽度
    max: Vec2 = .{},           // 内容最右下角
    widths: [max_widths]i32 = undefined, // 当前行各列宽度
    items: i32 = 0,            // 当前行列数
    item_index: i32 = 0,       // 当前列索引
    next_row: i32 = 0,         // 下一行起点 Y
    next_type: i32 = 0,        // layoutSetNext 类型：0 无 / 1 相对 / 2 绝对
    indent: i32 = 0,           // 树节点缩进
};

/// 容器（窗口/面板）
pub const Container = struct {
    head: ?usize = null,       // 头部跳转命令索引（根容器才有）
    tail: ?usize = null,       // 尾部跳转命令索引
    rect: Rect = .{},          // 整体矩形
    body: Rect = .{},          // 内容主体区域
    content_size: Vec2 = .{},  // 内容实际尺寸
    scroll: Vec2 = .{},        // 滚动偏移
    zindex: i32 = 0,           // 层级序号
    open: bool = true,         // 是否打开
};

/// 样式
pub const Style = struct {
    size: Vec2 = .{ .x = 68, .y = 10 }, // 默认控件尺寸
    padding: i32 = 5,                   // 内边距
    spacing: i32 = 4,                   // 控件间距
    indent: i32 = 24,                   // 树节点缩进
    title_height: i32 = 24,             // 标题栏高度
    scrollbar_size: i32 = 12,           // 滚动条宽度
    thumb_size: i32 = 8,                // 滚动条滑块最小尺寸
    colors: [color_count]Color = defaultColors(),
};

fn defaultColors() [color_count]Color {
    return .{
        .{ .r = 230, .g = 230, .b = 230, .a = 255 }, // text
        .{ .r = 25, .g = 25, .b = 25, .a = 255 },    // border
        .{ .r = 50, .g = 50, .b = 50, .a = 255 },    // window_bg
        .{ .r = 25, .g = 25, .b = 25, .a = 255 },    // title_bg
        .{ .r = 240, .g = 240, .b = 240, .a = 255 }, // title_text
        .{ .r = 0, .g = 0, .b = 0, .a = 0 },         // panel_bg（透明）
        .{ .r = 75, .g = 75, .b = 75, .a = 255 },    // button
        .{ .r = 95, .g = 95, .b = 95, .a = 255 },    // button_hover
        .{ .r = 115, .g = 115, .b = 115, .a = 255 }, // button_focus
        .{ .r = 30, .g = 30, .b = 30, .a = 255 },    // base
        .{ .r = 35, .g = 35, .b = 35, .a = 255 },    // base_hover
        .{ .r = 40, .g = 40, .b = 40, .a = 255 },    // base_focus
        .{ .r = 43, .g = 43, .b = 43, .a = 255 },    // scroll_base
        .{ .r = 30, .g = 30, .b = 30, .a = 255 },    // scroll_thumb
    };
}

/// 文本绘制命令
pub const TextCommand = struct {
    pos: Vec2 = .{},
    color: Color = .{},
    len: usize = 0,
    str: [text_cap]u8 = undefined,
};

/// 绘制命令联合体
pub const Command = union(enum) {
    jump: usize, // 跳转到另一条命令的索引
    clip: Rect,
    rect: struct { rect: Rect, color: Color },
    icon: struct { id: u32, rect: Rect, color: Color },
    text: TextCommand,
};

/// 命令遍历器（宿主在 mu.end 后使用）
pub const CommandIter = struct {
    ctx: *Context,
    idx: usize = 0,

    pub fn next(self: *CommandIter) ?Command {
        if (self.idx >= self.ctx.command_len) return null;
        const c = self.ctx.commands[self.idx];
        switch (c) {
            .jump => |dst| {
                self.idx = dst;
                return self.next();
            },
            else => {
                self.idx += 1;
                return c;
            },
        }
    }
};

/// 全局上下文
pub const Context = struct {
    // ---- 回调（宿主提供测量函数） ----
    text_width: *const fn (ctx: *Context, str: []const u8) i32 = defaultTextWidth,
    text_height: *const fn (ctx: *Context) i32 = defaultTextHeight,
    draw_frame: *const fn (ctx: *Context, rect: Rect, colorid: ColorId) void = defaultDrawFrame,

    // ---- 核心状态 ----
    default_style: Style = .{},
    style: *Style = undefined,

    hover: Id = 0,
    focus: Id = 0,
    last_id: Id = 0,
    last_rect: Rect = .{},
    last_zindex: i32 = 0,
    updated_focus: bool = false,
    frame: u32 = 0,

    hover_root: ?*Container = null,
    next_hover_root: ?*Container = null,
    scroll_target: ?*Container = null,

    number_edit_buf: [max_fmt]u8 = undefined,
    number_edit: Id = 0,

    // ---- 命令与栈 ----
    commands: [command_cap]Command = undefined,
    command_len: usize = 0,
    root_list: Stack(*Container, root_list_cap) = .{},
    container_stack: Stack(*Container, container_stack_cap) = .{},
    clip_stack: Stack(Rect, clip_stack_cap) = .{},
    id_stack: Stack(Id, id_stack_cap) = .{},
    layout_stack: Stack(Layout, layout_stack_cap) = .{},

    // ---- 对象池 ----
    container_pool: [container_pool_cap]PoolItem = [_]PoolItem{.{}} ** container_pool_cap,
    containers: [container_pool_cap]Container = [_]Container{.{}} ** container_pool_cap,
    treenode_pool: [treenode_pool_cap]PoolItem = [_]PoolItem{.{}} ** treenode_pool_cap,

    // ---- 输入状态 ----
    mouse_pos: Vec2 = .{},
    last_mouse_pos: Vec2 = .{},
    mouse_delta: Vec2 = .{},
    scroll_delta: Vec2 = .{},
    mouse_down: u8 = 0,
    mouse_pressed: u8 = 0,
    key_down: u8 = 0,
    key_pressed: u8 = 0,
    input_text: [32]u8 = undefined,
    input_text_len: usize = 0,

    // ===================== 生命周期 =====================

    pub fn init(ctx: *Context) void {
        ctx.* = .{};
        ctx.style = &ctx.default_style;
    }

    /// 开始一帧：清空命令与根容器，计算鼠标位移，帧号 +1
    pub fn begin(ctx: *Context) void {
        ctx.command_len = 0;
        ctx.root_list.len = 0;
        ctx.scroll_target = null;
        ctx.hover_root = ctx.next_hover_root;
        ctx.next_hover_root = null;
        ctx.mouse_delta.x = ctx.mouse_pos.x - ctx.last_mouse_pos.x;
        ctx.mouse_delta.y = ctx.mouse_pos.y - ctx.last_mouse_pos.y;
        ctx.frame += 1;
    }

    /// 结束一帧：处理滚动/焦点，整理根容器跳转链
    pub fn end(ctx: *Context) void {
        std.debug.assert(ctx.container_stack.len == 0);
        std.debug.assert(ctx.clip_stack.len == 0);
        std.debug.assert(ctx.id_stack.len == 0);
        std.debug.assert(ctx.layout_stack.len == 0);

        // 滚轮滚动量施加到滚动目标
        if (ctx.scroll_target) |t| {
            t.scroll.x += ctx.scroll_delta.x;
            t.scroll.y += ctx.scroll_delta.y;
        }

        // 本帧没有控件更新焦点则自动清除焦点
        if (!ctx.updated_focus) ctx.focus = 0;
        ctx.updated_focus = false;

        // 鼠标按下在更底层的悬停根容器上时，将其置顶
        if (ctx.mouse_pressed != 0) {
            if (ctx.next_hover_root) |nhr| {
                if (nhr.zindex < ctx.last_zindex and nhr.zindex >= 0) ctx.bringToFront(nhr);
            }
        }

        // 重置帧级输入
        ctx.key_pressed = 0;
        ctx.input_text_len = 0;
        ctx.mouse_pressed = 0;
        ctx.scroll_delta = .{};
        ctx.last_mouse_pos = ctx.mouse_pos;

        // 按 zindex 升序排序根容器（数量少，直接插入排序）
        const n = ctx.root_list.len;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const key = ctx.root_list.items[i];
            var j = i;
            while (j > 0 and ctx.root_list.items[j - 1].zindex > key.zindex) : (j -= 1) {
                ctx.root_list.items[j] = ctx.root_list.items[j - 1];
            }
            ctx.root_list.items[j] = key;
        }

        // 设置跳转链：入口跳转到第一个容器内容，各容器尾部跳转到下一个容器内容
        for (0..n) |k| {
            const cnt = ctx.root_list.items[k];
            if (k == 0) {
                ctx.commands[0].jump = cnt.head.? + 1;
            } else {
                const prev = ctx.root_list.items[k - 1];
                ctx.commands[prev.tail.?].jump = cnt.head.? + 1;
            }
            if (k == n - 1) ctx.commands[cnt.tail.?].jump = ctx.command_len;
        }
    }

    pub fn setFocus(ctx: *Context, id: Id) void {
        ctx.focus = id;
        ctx.updated_focus = true;
    }

    // ===================== ID 系统 =====================

    fn hash(h: *Id, data: []const u8) void {
        for (data) |b| h.* = (h.* ^ b) *% 16777619;
    }

    /// 由内容计算稳定 ID（相同内容 + 相同作用域 → 相同 ID）
    pub fn getId(ctx: *Context, data: []const u8) Id {
        var res: Id = if (ctx.id_stack.len > 0) ctx.id_stack.items[ctx.id_stack.len - 1] else 2166136261;
        hash(&res, data);
        ctx.last_id = res;
        return res;
    }

    pub fn pushId(ctx: *Context, data: []const u8) void {
        ctx.id_stack.push(ctx.getId(data));
    }

    pub fn popId(ctx: *Context) void {
        ctx.id_stack.pop();
    }

    // ===================== 裁剪 =====================

    pub fn pushClipRect(ctx: *Context, rect: Rect) void {
        const last = ctx.getClipRect();
        ctx.clip_stack.push(intersectRects(rect, last));
    }

    pub fn popClipRect(ctx: *Context) void {
        ctx.clip_stack.pop();
    }

    pub fn getClipRect(ctx: *Context) Rect {
        std.debug.assert(ctx.clip_stack.len > 0);
        return ctx.clip_stack.items[ctx.clip_stack.len - 1];
    }

    /// 检测矩形与裁剪区的关系：0 完全可见 / clip_part 部分可见 / clip_all 完全不可见
    pub fn checkClip(ctx: *Context, r: Rect) u8 {
        const cr = ctx.getClipRect();
        if (r.x > cr.x + cr.w or r.x + r.w < cr.x or
            r.y > cr.y + cr.h or r.y + r.h < cr.y) return clip_all;
        if (r.x >= cr.x and r.x + r.w <= cr.x + cr.w and
            r.y >= cr.y and r.y + r.h <= cr.y + cr.h) return 0;
        return clip_part;
    }

    // ===================== 布局 =====================

    fn pushLayout(ctx: *Context, body: Rect, scroll: Vec2) void {
        var layout: Layout = .{};
        layout.body = Rect.init(body.x - scroll.x, body.y - scroll.y, body.w, body.h);
        layout.max = .{ .x = -0x1000000, .y = -0x1000000 };
        ctx.layout_stack.push(layout);
        ctx.layoutRow(1, &.{0}, 0);
    }

    fn getLayout(ctx: *Context) *Layout {
        return ctx.layout_stack.topMut();
    }

    fn popContainer(ctx: *Context) void {
        const cnt = ctx.getCurrentContainer();
        const layout = ctx.getLayout();
        cnt.content_size.x = layout.max.x - layout.body.x;
        cnt.content_size.y = layout.max.y - layout.body.y;
        ctx.container_stack.pop();
        ctx.layout_stack.pop();
        ctx.popId();
    }

    pub fn getCurrentContainer(ctx: *Context) *Container {
        std.debug.assert(ctx.container_stack.len > 0);
        return ctx.container_stack.items[ctx.container_stack.len - 1];
    }

    fn getContainer(ctx: *Context, id: Id, opt: u16) ?*Container {
        if (ctx.poolGet(&ctx.container_pool, id)) |idx| {
            if (ctx.containers[idx].open or (opt & opt_closed) == 0) ctx.poolUpdate(&ctx.container_pool, idx);
            return &ctx.containers[idx];
        }
        if ((opt & opt_closed) != 0) return null;
        const idx = ctx.poolInit(&ctx.container_pool, id);
        const cnt = &ctx.containers[idx];
        cnt.* = .{};
        cnt.open = true;
        ctx.bringToFront(cnt);
        return cnt;
    }

    pub fn bringToFront(ctx: *Context, cnt: *Container) void {
        ctx.last_zindex += 1;
        cnt.zindex = ctx.last_zindex;
    }

    // ===================== 对象池 =====================

    fn poolGet(ctx: *Context, items: []PoolItem, id: Id) ?usize {
        _ = ctx;
        for (items, 0..) |item, i| if (item.id == id) return i;
        return null;
    }

    /// 初始化一个条目：占用"最久未更新"的空槽
    fn poolInit(ctx: *Context, items: []PoolItem, id: Id) usize {
        var n: usize = 0;
        var f: u32 = ctx.frame;
        for (items, 0..) |item, i| {
            if (item.last_update < f) {
                f = item.last_update;
                n = i;
            }
        }
        items[n].id = id;
        ctx.poolUpdate(items, n);
        return n;
    }

    fn poolUpdate(ctx: *Context, items: []PoolItem, idx: usize) void {
        items[idx].last_update = ctx.frame;
    }

    // ===================== 输入 =====================

    pub fn inputMouseMove(ctx: *Context, x: i32, y: i32) void {
        ctx.mouse_pos = .{ .x = x, .y = y };
    }

    pub fn inputMouseDown(ctx: *Context, x: i32, y: i32, btn: u8) void {
        ctx.inputMouseMove(x, y);
        ctx.mouse_down |= btn;
        ctx.mouse_pressed |= btn;
    }

    pub fn inputMouseUp(ctx: *Context, x: i32, y: i32, btn: u8) void {
        ctx.inputMouseMove(x, y);
        ctx.mouse_down &= ~btn;
    }

    pub fn inputScroll(ctx: *Context, x: i32, y: i32) void {
        ctx.scroll_delta.x += x;
        ctx.scroll_delta.y += y;
    }

    pub fn inputKeyDown(ctx: *Context, key: u8) void {
        ctx.key_pressed |= key;
        ctx.key_down |= key;
    }

    pub fn inputKeyUp(ctx: *Context, key: u8) void {
        ctx.key_down &= ~key;
    }

    pub fn inputText(ctx: *Context, input: []const u8) void {
        const n = @min(ctx.input_text.len - ctx.input_text_len, input.len);
        if (n > 0) {
            @memcpy(ctx.input_text[ctx.input_text_len..][0..n], input[0..n]);
            ctx.input_text_len += n;
        }
    }

    // ===================== 命令列表 =====================

    fn pushCommand(ctx: *Context, c: Command) usize {
        std.debug.assert(ctx.command_len < command_cap);
        const idx = ctx.command_len;
        ctx.commands[idx] = c;
        ctx.command_len += 1;
        return idx;
    }

    pub fn commandIter(ctx: *Context) CommandIter {
        return .{ .ctx = ctx };
    }

    pub fn setClip(ctx: *Context, rect: Rect) void {
        _ = ctx.pushCommand(.{ .clip = rect });
    }

    pub fn drawRect(ctx: *Context, rect: Rect, color: Color) void {
        const r = intersectRects(rect, ctx.getClipRect());
        if (r.w > 0 and r.h > 0) {
            _ = ctx.pushCommand(.{ .rect = .{ .rect = r, .color = color } });
        }
    }

    /// 画边框：四条细矩形
    pub fn drawBox(ctx: *Context, rect: Rect, color: Color) void {
        ctx.drawRect(Rect.init(rect.x + 1, rect.y, rect.w - 2, 1), color);
        ctx.drawRect(Rect.init(rect.x + 1, rect.y + rect.h - 1, rect.w - 2, 1), color);
        ctx.drawRect(Rect.init(rect.x, rect.y, 1, rect.h), color);
        ctx.drawRect(Rect.init(rect.x + rect.w - 1, rect.y, 1, rect.h), color);
    }

    pub fn drawText(ctx: *Context, str: []const u8, pos: Vec2, color: Color) void {
        const rect = Rect.init(pos.x, pos.y, ctx.text_width(ctx, str), ctx.text_height(ctx));
        const clipped = ctx.checkClip(rect);
        if (clipped == clip_all) return;
        if (clipped == clip_part) ctx.setClip(ctx.getClipRect());
        // 文本直接拷贝进命令（超过 text_cap 的截断）
        var cmd = TextCommand{ .pos = pos, .color = color, .len = @min(str.len, text_cap) };
        @memcpy(cmd.str[0..cmd.len], str[0..cmd.len]);
        _ = ctx.pushCommand(.{ .text = cmd });
        if (clipped != 0) ctx.setClip(unclipped_rect);
    }

    pub fn drawIcon(ctx: *Context, id: u32, rect: Rect, color: Color) void {
        const clipped = ctx.checkClip(rect);
        if (clipped == clip_all) return;
        if (clipped == clip_part) ctx.setClip(ctx.getClipRect());
        _ = ctx.pushCommand(.{ .icon = .{ .id = id, .rect = rect, .color = color } });
        if (clipped != 0) ctx.setClip(unclipped_rect);
    }

    // ===================== 布局 API =====================

    pub fn layoutBeginColumn(ctx: *Context) void {
        ctx.pushLayout(ctx.layoutNext(), .{});
    }

    pub fn layoutEndColumn(ctx: *Context) void {
        const b = ctx.layout_stack.top();
        ctx.layout_stack.pop();
        const a = ctx.layout_stack.topMut();
        a.position.x = @max(a.position.x, b.position.x + b.body.x - a.body.x);
        a.next_row = @max(a.next_row, b.next_row + b.body.y - a.body.y);
        a.max.x = @max(a.max.x, b.max.x);
        a.max.y = @max(a.max.y, b.max.y);
    }

    pub fn layoutRow(ctx: *Context, items: i32, widths: ?[]const i32, height: i32) void {
        const layout = ctx.getLayout();
        if (widths) |ws| {
            std.debug.assert(items <= max_widths);
            const n: usize = @intCast(items);
            @memcpy(layout.widths[0..n], ws[0..n]);
        }
        layout.items = items;
        layout.position = .{ .x = layout.indent, .y = layout.next_row };
        layout.size.y = height;
        layout.item_index = 0;
    }

    pub fn layoutWidth(ctx: *Context, width: i32) void {
        ctx.getLayout().size.x = width;
    }

    pub fn layoutHeight(ctx: *Context, height: i32) void {
        ctx.getLayout().size.y = height;
    }

    pub fn layoutSetNext(ctx: *Context, r: Rect, relative: bool) void {
        const layout = ctx.getLayout();
        layout.next = r;
        layout.next_type = if (relative) 1 else 2;
    }

    pub fn layoutNext(ctx: *Context) Rect {
        const layout = ctx.getLayout();
        var res: Rect = .{};

        if (layout.next_type != 0) {
            // 情况一：矩形由 layoutSetNext 预先指定
            const t = layout.next_type;
            layout.next_type = 0;
            res = layout.next;
            if (t == 2) { // 绝对坐标，直接返回
                ctx.last_rect = res;
                return res;
            }
        } else {
            // 情况二：按行自动推进
            if (layout.item_index == layout.items) ctx.layoutRow(layout.items, null, layout.size.y);
            res.x = layout.position.x;
            res.y = layout.position.y;
            res.w = if (layout.items > 0) layout.widths[@intCast(layout.item_index)] else layout.size.x;
            res.h = layout.size.y;
            if (res.w == 0) res.w = ctx.style.size.x + ctx.style.padding * 2;
            if (res.h == 0) res.h = ctx.style.size.y + ctx.style.padding * 2;
            if (res.w < 0) res.w += layout.body.w - res.x + 1;
            if (res.h < 0) res.h += layout.body.h - res.y + 1;
            layout.item_index += 1;
        }

        // 推进位置
        layout.position.x += res.w + ctx.style.spacing;
        layout.next_row = @max(layout.next_row, res.y + res.h + ctx.style.spacing);

        // 应用 body 偏移（布局坐标相对 body，这里转全局坐标）
        res.x += layout.body.x;
        res.y += layout.body.y;

        // 更新内容最大边界
        layout.max.x = @max(layout.max.x, res.x + res.w);
        layout.max.y = @max(layout.max.y, res.y + res.h);

        ctx.last_rect = res;
        return res;
    }

    // ===================== 控件公共底层 =====================

    fn inHoverRoot(ctx: *Context) bool {
        var i: usize = ctx.container_stack.len;
        while (i > 0) {
            i -= 1;
            const cnt = ctx.container_stack.items[i];
            if (ctx.hover_root) |hr| {
                if (cnt == hr) return true;
            }
            // 只有根容器才有 head 命令；遇到根容器即可停止向上查找
            if (cnt.head != null) break;
        }
        return false;
    }

    /// 绘制控件底色（根据悬停/焦点自动叠加颜色偏移）
    pub fn drawControlFrame(ctx: *Context, id: Id, rect: Rect, colorid: ColorId, opt: u16) void {
        if ((opt & opt_no_frame) != 0) return;
        const cid = controlColor(colorid, ctx.focus == id, ctx.hover == id);
        ctx.draw_frame(ctx, rect, cid);
    }

    /// 在控件矩形内绘制文字（支持居中/右对齐，限制在矩形内裁剪）
    pub fn drawControlText(ctx: *Context, str: []const u8, rect: Rect, colorid: ColorId, opt: u16) void {
        var pos: Vec2 = .{};
        const tw = ctx.text_width(ctx, str);
        ctx.pushClipRect(rect);
        pos.y = rect.y + @divTrunc(rect.h - ctx.text_height(ctx), 2);
        if ((opt & opt_align_center) != 0) {
            pos.x = rect.x + @divTrunc(rect.w - tw, 2);
        } else if ((opt & opt_align_right) != 0) {
            pos.x = rect.x + rect.w - tw - ctx.style.padding;
        } else {
            pos.x = rect.x + ctx.style.padding;
        }
        ctx.drawText(str, pos, ctx.style.colors[@intFromEnum(colorid)]);
        ctx.popClipRect();
    }

    pub fn mouseOver(ctx: *Context, rect: Rect) bool {
        return rectOverlapsVec2(rect, ctx.mouse_pos) and
            rectOverlapsVec2(ctx.getClipRect(), ctx.mouse_pos) and
            ctx.inHoverRoot();
    }

    /// 更新控件的悬停/焦点状态
    pub fn updateControl(ctx: *Context, id: Id, rect: Rect, opt: u16) void {
        const mouseover = ctx.mouseOver(rect);
        if (ctx.focus == id) ctx.updated_focus = true;
        if ((opt & opt_no_interact) != 0) return;
        if (mouseover and ctx.mouse_down == 0) ctx.hover = id;

        if (ctx.focus == id) {
            if (ctx.mouse_pressed != 0 and !mouseover) ctx.setFocus(0);
            if (ctx.mouse_down == 0 and (opt & opt_hold_focus) == 0) ctx.setFocus(0);
        }

        if (ctx.hover == id) {
            if (ctx.mouse_pressed != 0) {
                ctx.setFocus(id);
            } else if (!mouseover) {
                ctx.hover = 0;
            }
        }
    }

    // ===================== 控件 =====================

    /// 自动换行文本块（按空格拆词，超宽换行，\n 强制换行）
    pub fn text(ctx: *Context, s: []const u8) void {
        var p: usize = 0;
        ctx.layoutBeginColumn();
        ctx.layoutRow(1, &.{-1}, ctx.text_height(ctx));
        while (p < s.len) {
            const r = ctx.layoutNext();
            const start: usize = p;
            var line_end: usize = p;
            var w: i32 = 0;
            while (true) {
                const word = p;
                while (p < s.len and s[p] != ' ' and s[p] != '\n') p += 1;
                w += ctx.text_width(ctx, s[word..p]);
                if (w > r.w and line_end != start) break;
                if (p < s.len) w += ctx.text_width(ctx, s[p .. p + 1]);
                line_end = p;
                p += 1;
                if (line_end >= s.len or s[line_end] == '\n') break;
            }
            ctx.drawText(s[start..line_end], .{ .x = r.x, .y = r.y }, ctx.style.colors[@intFromEnum(ColorId.text)]);
            p = line_end + 1;
        }
        ctx.layoutEndColumn();
    }

    pub fn label(ctx: *Context, text_str: []const u8) void {
        ctx.drawControlText(text_str, ctx.layoutNext(), .text, 0);
    }

    pub fn button(ctx: *Context, label_str: []const u8) u8 {
        return ctx.buttonEx(label_str, null, opt_align_center);
    }

    pub fn buttonEx(ctx: *Context, label_str: ?[]const u8, icon: ?u32, opt: u16) u8 {
        var res: u8 = 0;
        const id = if (label_str) |l|
            ctx.getId(l)
        else blk: {
            const ic = icon orelse 0;
            break :blk ctx.getId(std.mem.asBytes(&ic));
        };
        const r = ctx.layoutNext();
        ctx.updateControl(id, r, opt);
        if (ctx.mouse_pressed == mouse_left and ctx.focus == id) res |= res_submit;
        ctx.drawControlFrame(id, r, .button, opt);
        if (label_str) |l| ctx.drawControlText(l, r, .text, opt);
        if (icon) |ic| ctx.drawIcon(ic, r, ctx.style.colors[@intFromEnum(ColorId.text)]);
        return res;
    }

    pub fn checkbox(ctx: *Context, label_str: []const u8, state: *bool) u8 {
        var res: u8 = 0;
        const id = ctx.getId(std.mem.asBytes(&state));
        var r = ctx.layoutNext();
        const box = Rect.init(r.x, r.y, r.h, r.h);
        ctx.updateControl(id, r, 0);
        if (ctx.mouse_pressed == mouse_left and ctx.focus == id) {
            res |= res_change;
            state.* = !state.*;
        }
        ctx.drawControlFrame(id, box, .base, 0);
        if (state.*) ctx.drawIcon(@intFromEnum(Icon.check), box, ctx.style.colors[@intFromEnum(ColorId.text)]);
        r = Rect.init(r.x + box.w, r.y, r.w - box.w, r.h);
        ctx.drawControlText(label_str, r, .text, 0);
        return res;
    }

    /// 文本框底层实现
    pub fn textboxRaw(ctx: *Context, buf: []u8, id: Id, r: Rect, opt: u16) u8 {
        var res: u8 = 0;
        ctx.updateControl(id, r, opt | opt_hold_focus);

        if (ctx.focus == id) {
            var len = cstrLen(buf);
            // 追加文本输入（缓冲区已满则跳过，防止越界）
            const n = if (len + 1 < buf.len) @min(buf.len - len - 1, ctx.input_text_len) else 0;
            if (n > 0) {
                @memcpy(buf[len..][0..n], ctx.input_text[0..n]);
                len += n;
                buf[len] = 0;
                res |= res_change;
            }
            // 退格：向前删除一个 UTF-8 字符
            if ((ctx.key_pressed & key_backspace) != 0 and len > 0) {
                len -= 1;
                while (len > 0 and (buf[len] & 0xc0) == 0x80) len -= 1;
                buf[len] = 0;
                res |= res_change;
            }
            // 回车：提交并释放焦点
            if ((ctx.key_pressed & key_return) != 0) {
                ctx.setFocus(0);
                res |= res_submit;
            }
        }

        // 绘制
        ctx.drawControlFrame(id, r, .base, opt);
        if (ctx.focus == id) {
            // 聚焦：文本右对齐滚动 + 绘制光标
            const color = ctx.style.colors[@intFromEnum(ColorId.text)];
            const textw = ctx.text_width(ctx, buf[0..cstrLen(buf)]);
            const texth = ctx.text_height(ctx);
            const ofx = r.w - ctx.style.padding - textw - 1;
            const textx = r.x + @min(ofx, ctx.style.padding);
            const texty = r.y + @divTrunc(r.h - texth, 2);
            ctx.pushClipRect(r);
            ctx.drawText(buf[0..cstrLen(buf)], .{ .x = textx, .y = texty }, color);
            ctx.drawRect(Rect.init(textx + textw, texty, 1, texth), color); // 光标
            ctx.popClipRect();
        } else {
            ctx.drawControlText(buf[0..cstrLen(buf)], r, .text, opt);
        }

        return res;
    }

    pub fn textbox(ctx: *Context, buf: []u8) u8 {
        return ctx.textboxEx(buf, 0);
    }

    pub fn textboxEx(ctx: *Context, buf: []u8, opt: u16) u8 {
        const id = ctx.getId(std.mem.asBytes(&buf));
        const r = ctx.layoutNext();
        return ctx.textboxRaw(buf, id, r, opt);
    }

    /// 数字编辑模式：Shift+点击进入文本框直接输入数值
    fn numberTextbox(ctx: *Context, value: *Real, r: Rect, id: Id) bool {
        if (ctx.mouse_pressed == mouse_left and (ctx.key_down & key_shift) != 0 and ctx.hover == id) {
            ctx.number_edit = id;
            const s = std.fmt.bufPrint(&ctx.number_edit_buf, "{d}", .{value.*}) catch unreachable;
            ctx.number_edit_buf[s.len] = 0;
        }
        if (ctx.number_edit == id) {
            const res = ctx.textboxRaw(&ctx.number_edit_buf, id, r, 0);
            if ((res & res_submit) != 0 or ctx.focus != id) {
                value.* = std.fmt.parseFloat(Real, cstrSlice(&ctx.number_edit_buf)) catch 0;
                ctx.number_edit = 0;
            } else {
                return true;
            }
        }
        return false;
    }

    pub fn slider(ctx: *Context, value: *Real, low: Real, high: Real) u8 {
        return ctx.sliderEx(value, low, high, 0, "{d:.2}", opt_align_center);
    }

    pub fn sliderEx(
        ctx: *Context,
        value: *Real,
        low: Real,
        high: Real,
        step: Real,
        comptime fmt: []const u8,
        opt: u16,
    ) u8 {
        var buf: [max_fmt + 1]u8 = undefined;
        var res: u8 = 0;
        const last = value.*;
        var v = last;
        const id = ctx.getId(std.mem.asBytes(&value));
        const base = ctx.layoutNext();

        // 文本编辑模式（编辑中则跳过正常绘制）
        if (ctx.numberTextbox(&v, base, id)) return res;

        ctx.updateControl(id, base, opt);

        // 拖动输入
        if (ctx.focus == id and (ctx.mouse_down | ctx.mouse_pressed) == mouse_left) {
            v = low + @as(Real, @floatFromInt(ctx.mouse_pos.x - base.x)) *
                (high - low) / @as(Real, @floatFromInt(base.w));
            if (step != 0) {
                v = @as(Real, @floatFromInt(
                    @divTrunc(@as(i64, @intFromFloat(v + step / 2)), @as(i64, @intFromFloat(step))),
                )) * step;
            }
        }

        // 钳制并写回
        value.* = std.math.clamp(v, low, high);
        v = value.*;
        if (last != v) res |= res_change;

        // 绘制轨道 + 滑块 + 数值
        ctx.drawControlFrame(id, base, .base, opt);
        const w = ctx.style.thumb_size;
        const x: i32 = @intFromFloat((v - low) * @as(Real, @floatFromInt(base.w - w)) / (high - low));
        const thumb = Rect.init(base.x + x, base.y, w, base.h);
        ctx.drawControlFrame(id, thumb, .button, opt);
        const s = std.fmt.bufPrint(&buf, fmt, .{v}) catch unreachable;
        ctx.drawControlText(s, base, .text, opt);

        return res;
    }

    pub fn number(ctx: *Context, value: *Real, step: Real) u8 {
        return ctx.numberEx(value, step, "{d}", opt_align_center);
    }

    pub fn numberEx(ctx: *Context, value: *Real, step: Real, comptime fmt: []const u8, opt: u16) u8 {
        var buf: [max_fmt + 1]u8 = undefined;
        var res: u8 = 0;
        const id = ctx.getId(std.mem.asBytes(&value));
        const base = ctx.layoutNext();
        const last = value.*;

        if (ctx.numberTextbox(value, base, id)) return res;

        ctx.updateControl(id, base, opt);

        // 按住左键横向拖动调整数值
        if (ctx.focus == id and ctx.mouse_down == mouse_left) {
            value.* += @as(Real, @floatFromInt(ctx.mouse_delta.x)) * step;
        }
        if (value.* != last) res |= res_change;

        ctx.drawControlFrame(id, base, .base, opt);
        const s = std.fmt.bufPrint(&buf, fmt, .{value.*}) catch unreachable;
        ctx.drawControlText(s, base, .text, opt);

        return res;
    }

    pub fn header(ctx: *Context, label_str: []const u8) u8 {
        return ctx.headerEx(label_str, 0);
    }

    pub fn headerEx(ctx: *Context, label_str: []const u8, opt: u16) u8 {
        return headerImpl(ctx, label_str, false, opt);
    }

    /// 可折叠头部的公共实现（服务 headerEx 与树节点）
    fn headerImpl(ctx: *Context, label_str: []const u8, is_treenode: bool, opt: u16) u8 {
        const id = ctx.getId(label_str);
        const idx = ctx.poolGet(&ctx.treenode_pool, id);
        ctx.layoutRow(1, &.{-1}, 0);

        var active = idx != null;
        const expanded = if ((opt & opt_expanded) != 0) !active else active;
        const r = ctx.layoutNext();
        ctx.updateControl(id, r, 0);

        // 点击翻转激活状态
        if (ctx.mouse_pressed == mouse_left and ctx.focus == id) active = !active;

        // 更新对象池记录
        if (idx) |i| {
            if (active) ctx.poolUpdate(&ctx.treenode_pool, i) else ctx.treenode_pool[i] = .{};
        } else if (active) {
            _ = ctx.poolInit(&ctx.treenode_pool, id);
        }

        // 绘制
        if (is_treenode) {
            if (ctx.hover == id) ctx.draw_frame(ctx, r, .button_hover);
        } else {
            ctx.drawControlFrame(id, r, .button, 0);
        }
        ctx.drawIcon(
            @intFromEnum(if (expanded) Icon.expanded else Icon.collapsed),
            Rect.init(r.x, r.y, r.h, r.h),
            ctx.style.colors[@intFromEnum(ColorId.text)],
        );
        // 图标右侧绘制标题
        var rr = r;
        rr.x += r.h - ctx.style.padding;
        rr.w -= r.h - ctx.style.padding;
        ctx.drawControlText(label_str, rr, .text, 0);

        return if (expanded) res_active else 0;
    }

    pub fn beginTreeNode(ctx: *Context, label_str: []const u8) u8 {
        return ctx.beginTreeNodeEx(label_str, 0);
    }

    pub fn beginTreeNodeEx(ctx: *Context, label_str: []const u8, opt: u16) u8 {
        const res = headerImpl(ctx, label_str, true, opt);
        if ((res & res_active) != 0) {
            ctx.getLayout().indent += ctx.style.indent;
            ctx.id_stack.push(ctx.last_id);
        }
        return res;
    }

    pub fn endTreeNode(ctx: *Context) void {
        ctx.getLayout().indent -= ctx.style.indent;
        ctx.popId();
    }

    /// 滚动条（vert=true 为垂直滚动条，否则为水平滚动条）
    fn scrollbar(ctx: *Context, cnt: *Container, b: *Rect, cs: Vec2, vert: bool) void {
        const max_scroll = if (vert) cs.y - b.h else cs.x - b.w;
        const bh = if (vert) b.h else b.w;

        if (max_scroll > 0 and bh > 0) {
            var base = b.*;
            if (vert) {
                base.x = b.x + b.w;
                base.w = ctx.style.scrollbar_size;
            } else {
                base.y = b.y + b.h;
                base.h = ctx.style.scrollbar_size;
            }
            // 用轴名生成唯一 ID
            const id = ctx.getId(if (vert) "!scrollbary" else "!scrollbarx");

            ctx.updateControl(id, base, 0);
            if (ctx.focus == id and ctx.mouse_down == mouse_left) {
                if (vert) {
                    cnt.scroll.y += @intFromFloat(
                        @as(Real, @floatFromInt(ctx.mouse_delta.y)) * @as(Real, @floatFromInt(cs.y)) /
                            @as(Real, @floatFromInt(base.h)),
                    );
                } else {
                    cnt.scroll.x += @intFromFloat(
                        @as(Real, @floatFromInt(ctx.mouse_delta.x)) * @as(Real, @floatFromInt(cs.x)) /
                            @as(Real, @floatFromInt(base.w)),
                    );
                }
            }
            if (vert) cnt.scroll.y = std.math.clamp(cnt.scroll.y, 0, max_scroll) else cnt.scroll.x = std.math.clamp(cnt.scroll.x, 0, max_scroll);

            // 绘制轨道与滑块
            ctx.draw_frame(ctx, base, .scroll_base);
            var thumb = base;
            if (vert) {
                thumb.h = @max(ctx.style.thumb_size, @as(i32, @intFromFloat(
                    @as(Real, @floatFromInt(base.h)) * @as(Real, @floatFromInt(bh)) / @as(Real, @floatFromInt(cs.y)),
                )));
                thumb.y += @divTrunc(cnt.scroll.y * (base.h - thumb.h), max_scroll);
            } else {
                thumb.w = @max(ctx.style.thumb_size, @as(i32, @intFromFloat(
                    @as(Real, @floatFromInt(base.w)) * @as(Real, @floatFromInt(bh)) / @as(Real, @floatFromInt(cs.x)),
                )));
                thumb.x += @divTrunc(cnt.scroll.x * (base.w - thumb.w), max_scroll);
            }
            ctx.draw_frame(ctx, thumb, .scroll_thumb);

            // 鼠标在主体上时登记为滚轮滚动目标
            if (ctx.mouseOver(b.*)) ctx.scroll_target = cnt;
        } else {
            if (vert) cnt.scroll.y = 0 else cnt.scroll.x = 0;
        }
    }

    fn scrollbars(ctx: *Context, cnt: *Container, body: *Rect) void {
        const sz = ctx.style.scrollbar_size;
        var cs = cnt.content_size;
        cs.x += ctx.style.padding * 2;
        cs.y += ctx.style.padding * 2;
        ctx.pushClipRect(body.*);
        // 缩小主体以腾出滚动条位置
        if (cs.y > cnt.body.h) body.w -= sz;
        if (cs.x > cnt.body.w) body.h -= sz;
        ctx.scrollbar(cnt, body, cs, true);
        ctx.scrollbar(cnt, body, cs, false);
        ctx.popClipRect();
    }

    fn pushContainerBody(ctx: *Context, cnt: *Container, body: Rect, opt: u16) void {
        var b = body;
        if ((opt & opt_no_scroll) == 0) ctx.scrollbars(cnt, &b);
        ctx.pushLayout(expandRect(b, -ctx.style.padding), cnt.scroll);
        cnt.body = b;
    }

    fn beginRootContainer(ctx: *Context, cnt: *Container) void {
        ctx.container_stack.push(cnt);
        ctx.root_list.push(cnt);
        cnt.head = ctx.pushCommand(.{ .jump = 0 });
        if (rectOverlapsVec2(cnt.rect, ctx.mouse_pos) and
            (ctx.next_hover_root == null or cnt.zindex > ctx.next_hover_root.?.zindex))
        {
            ctx.next_hover_root = cnt;
        }
        // 重置裁剪，防止内层根容器被外层窗口裁剪
        ctx.clip_stack.push(unclipped_rect);
    }

    fn endRootContainer(ctx: *Context) void {
        const cnt = ctx.getCurrentContainer();
        cnt.tail = ctx.pushCommand(.{ .jump = 0 });
        ctx.commands[cnt.head.?].jump = ctx.command_len; // 头部跳转：跳过本容器内容
        ctx.popClipRect();
        ctx.popContainer();
    }

    // ===================== 窗口 / 面板 =====================

    pub fn beginWindow(ctx: *Context, title: []const u8, rect: Rect) u8 {
        return ctx.beginWindowEx(title, rect, 0);
    }

    pub fn beginWindowEx(ctx: *Context, title: []const u8, rect: Rect, opt: u16) u8 {
        const id = ctx.getId(title);
        const cnt = ctx.getContainer(id, opt) orelse return 0;
        if (!cnt.open) return 0;
        ctx.id_stack.push(id);

        if (cnt.rect.w == 0) cnt.rect = rect;
        ctx.beginRootContainer(cnt);
        var body = cnt.rect;

        // 窗口背景
        if ((opt & opt_no_frame) == 0) ctx.draw_frame(ctx, cnt.rect, .window_bg);

        // 标题栏
        if ((opt & opt_no_title) == 0) {
            var tr = cnt.rect;
            tr.h = ctx.style.title_height;
            ctx.draw_frame(ctx, tr, .title_bg);

            // 标题文字 + 拖动窗口
            {
                const tid = ctx.getId("!title");
                ctx.updateControl(tid, tr, opt);
                ctx.drawControlText(title, tr, .title_text, opt);
                if (tid == ctx.focus and ctx.mouse_down == mouse_left) {
                    cnt.rect.x += ctx.mouse_delta.x;
                    cnt.rect.y += ctx.mouse_delta.y;
                }
                body.y += tr.h;
                body.h -= tr.h;
            }

            // 关闭按钮
            if ((opt & opt_no_close) == 0) {
                const cid = ctx.getId("!close");
                const r = Rect.init(tr.x + tr.w - tr.h, tr.y, tr.h, tr.h);
                ctx.drawIcon(@intFromEnum(Icon.close), r, ctx.style.colors[@intFromEnum(ColorId.title_text)]);
                ctx.updateControl(cid, r, opt);
                if (ctx.mouse_pressed == mouse_left and cid == ctx.focus) cnt.open = false;
            }
        }

        ctx.pushContainerBody(cnt, body, opt);

        // 右下角调整大小手柄
        if ((opt & opt_no_resize) == 0) {
            const sz = ctx.style.title_height;
            const rid = ctx.getId("!resize");
            const r = Rect.init(cnt.rect.x + cnt.rect.w - sz, cnt.rect.y + cnt.rect.h - sz, sz, sz);
            ctx.updateControl(rid, r, opt);
            if (rid == ctx.focus and ctx.mouse_down == mouse_left) {
                cnt.rect.w = @max(96, cnt.rect.w + ctx.mouse_delta.x);
                cnt.rect.h = @max(64, cnt.rect.h + ctx.mouse_delta.y);
            }
        }

        // 尺寸自适应内容
        if ((opt & opt_auto_size) != 0) {
            const r = ctx.getLayout().body;
            cnt.rect.w = cnt.content_size.x + (cnt.rect.w - r.w);
            cnt.rect.h = cnt.content_size.y + (cnt.rect.h - r.h);
        }

        // 弹出窗口：点击外部自动关闭
        if ((opt & opt_popup) != 0 and ctx.mouse_pressed != 0) {
            if (ctx.hover_root) |hr| {
                if (hr != cnt) cnt.open = false;
            } else cnt.open = false;
        }

        ctx.pushClipRect(cnt.body);
        return res_active;
    }

    pub fn endWindow(ctx: *Context) void {
        ctx.popClipRect();
        ctx.endRootContainer();
    }

    pub fn openPopup(ctx: *Context, name: []const u8) void {
        const cnt = ctx.getContainer(ctx.getId(name), 0) orelse return;
        // 设为悬停根容器，防止 beginWindowEx 立即关闭它
        ctx.hover_root = cnt;
        ctx.next_hover_root = cnt;
        // 定位到鼠标处、打开并置顶
        cnt.rect = Rect.init(ctx.mouse_pos.x, ctx.mouse_pos.y, 1, 1);
        cnt.open = true;
        ctx.bringToFront(cnt);
    }

    pub fn beginPopup(ctx: *Context, name: []const u8) u8 {
        const opt = opt_popup | opt_auto_size | opt_no_resize | opt_no_scroll | opt_no_title | opt_closed;
        return ctx.beginWindowEx(name, .{}, opt);
    }

    pub fn endPopup(ctx: *Context) void {
        ctx.endWindow();
    }

    pub fn beginPanel(ctx: *Context, name: []const u8) void {
        ctx.beginPanelEx(name, 0);
    }

    pub fn beginPanelEx(ctx: *Context, name: []const u8, opt: u16) void {
        ctx.pushId(name);
        const cnt = ctx.getContainer(ctx.last_id, opt) orelse unreachable;
        cnt.rect = ctx.layoutNext();
        if ((opt & opt_no_frame) == 0) ctx.draw_frame(ctx, cnt.rect, .panel_bg);
        ctx.container_stack.push(cnt);
        ctx.pushContainerBody(cnt, cnt.rect, opt);
        ctx.pushClipRect(cnt.body);
    }

    pub fn endPanel(ctx: *Context) void {
        ctx.popClipRect();
        ctx.popContainer();
    }
};

// ===================== 内部工具 =====================

/// 读取 C 风格字符串（NUL 结尾）的长度
fn cstrLen(buf: []const u8) usize {
    for (buf, 0..) |ch, i| if (ch == 0) return i;
    return buf.len;
}

/// 读取 C 风格字符串切片（到 NUL 为止）
fn cstrSlice(buf: []const u8) []const u8 {
    return buf[0..cstrLen(buf)];
}

fn expandRect(rect: Rect, n: i32) Rect {
    return Rect.init(rect.x - n, rect.y - n, rect.w + n * 2, rect.h + n * 2);
}

fn intersectRects(r1: Rect, r2: Rect) Rect {
    const x1 = @max(r1.x, r2.x);
    const y1 = @max(r1.y, r2.y);
    var x2 = @min(r1.x + r1.w, r2.x + r2.w);
    var y2 = @min(r1.y + r1.h, r2.y + r2.h);
    if (x2 < x1) x2 = x1;
    if (y2 < y1) y2 = y1;
    return Rect.init(x1, y1, x2 - x1, y2 - y1);
}

fn rectOverlapsVec2(r: Rect, p: Vec2) bool {
    return p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h;
}

/// 控件底色颜色偏移：常规 → 悬停(+1) → 聚焦(+2)
fn controlColor(base: ColorId, focus: bool, hover: bool) ColorId {
    const b = @intFromEnum(base);
    const off: usize = if (focus) 2 else if (hover) 1 else 0;
    return @enumFromInt(b + off);
}

fn defaultTextWidth(ctx: *Context, str: []const u8) i32 {
    _ = ctx;
    return @intCast(str.len * 8);
}

fn defaultTextHeight(ctx: *Context) i32 {
    _ = ctx;
    return 16;
}

/// 默认控件背景绘制：填充颜色 + 外圈边框
fn defaultDrawFrame(ctx: *Context, rect: Rect, colorid: ColorId) void {
    ctx.drawRect(rect, ctx.style.colors[@intFromEnum(colorid)]);
    if (colorid == .scroll_base or colorid == .scroll_thumb or colorid == .title_bg) return;
    if (ctx.style.colors[@intFromEnum(ColorId.border)].a != 0) {
        ctx.drawBox(expandRect(rect, 1), ctx.style.colors[@intFromEnum(ColorId.border)]);
    }
}
