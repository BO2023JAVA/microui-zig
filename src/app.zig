//! microui 示例应用内容（平台无关）
//!
//! 这里只包含"界面长什么样、逻辑做什么"，不依赖任何平台 API：
//! - 三个示例窗口（演示窗口 / 日志窗口 / 样式编辑器）及各自状态；
//! - 每帧构建流程 processFrame；
//! - 现代暗色主题 applyTheme。
//!
//! 桌面版（demo.zig）和 Android 版（main_android.zig）共用本模块，
//! 各自只负责"输入事件来源 + 渲染后端"。

const std = @import("std");
const microui = @import("microui");

// ===================== 跨帧保留的界面状态 =====================

pub var log_buf: [64000]u8 = undefined;
pub var log_len: usize = 0;
pub var log_updated: bool = false;
pub var bg = [3]f32{ 44, 48, 57 }; // 默认背景（现代暗色调，窗口半透明时透出）
var test_checks = [3]bool{ true, false, true }; // 复选框勾选状态
pub var log_input = [_]u8{0} ** 128; // 日志输入框缓冲

pub fn writeLog(text: []const u8) void {
    if (log_len > 0) {
        if (log_len < log_buf.len) log_buf[log_len] = '\n';
        log_len += 1;
    }
    const n = @min(log_buf.len - log_len, text.len);
    @memcpy(log_buf[log_len..][0..n], text[0..n]);
    log_len += n;
    log_updated = true;
}

// ===================== 演示窗口 =====================

fn testWindow(ctx: *microui.Context) void {
    if (ctx.beginWindow("演示窗口", microui.Rect.init(40, 40, 300, 450)) != 0) {
        const win = ctx.getCurrentContainer();
        win.rect.w = @max(win.rect.w, 240);
        win.rect.h = @max(win.rect.h, 300);

        // 窗口信息
        if (ctx.header("窗口信息") != 0) {
            const w = ctx.getCurrentContainer();
            var buf: [64]u8 = undefined;
            ctx.layoutRow(2, &.{ 54, -1 }, 0);
            ctx.label("位置:");
            const pos = std.fmt.bufPrint(&buf, "{d}, {d}", .{ w.rect.x, w.rect.y }) catch unreachable;
            ctx.label(pos);
            ctx.label("尺寸:");
            const sz = std.fmt.bufPrint(&buf, "{d}, {d}", .{ w.rect.w, w.rect.h }) catch unreachable;
            ctx.label(sz);
        }

        // 测试按钮 + 弹出菜单
        if (ctx.headerEx("测试按钮", microui.opt_expanded) != 0) {
            ctx.layoutRow(3, &.{ 86, -110, -1 }, 0);
            ctx.label("按钮组 1:");
            if (ctx.button("按钮 1") != 0) writeLog("按下了按钮 1");
            if (ctx.button("按钮 2") != 0) writeLog("按下了按钮 2");
            ctx.label("按钮组 2:");
            if (ctx.button("按钮 3") != 0) writeLog("按下了按钮 3");
            if (ctx.button("弹出") != 0) ctx.openPopup("测试弹出");
            if (ctx.beginPopup("测试弹出") != 0) {
                _ = ctx.button("你好");
                _ = ctx.button("microUi");
                ctx.endPopup();
            }
        }

        // 树节点 + 自动换行文本
        if (ctx.headerEx("树与文本", microui.opt_expanded) != 0) {
            ctx.layoutRow(2, &.{ 140, -1 }, 0);
            ctx.layoutBeginColumn();
            if (ctx.beginTreeNode("测试 1") != 0) {
                if (ctx.beginTreeNode("测试 1a") != 0) {
                    ctx.label("你好");
                    ctx.label("microUi");
                    ctx.endTreeNode();
                }
                if (ctx.beginTreeNode("测试 1b") != 0) {
                    if (ctx.button("按钮 1") != 0) writeLog("按下了按钮 1");
                    if (ctx.button("按钮 2") != 0) writeLog("按下了按钮 2");
                    ctx.endTreeNode();
                }
                ctx.endTreeNode();
            }
            if (ctx.beginTreeNode("测试 2") != 0) {
                ctx.layoutRow(2, &.{ 54, 54 }, 0);
                if (ctx.button("按钮 3") != 0) writeLog("按下了按钮 3");
                if (ctx.button("按钮 4") != 0) writeLog("按下了按钮 4");
                if (ctx.button("按钮 5") != 0) writeLog("按下了按钮 5");
                if (ctx.button("按钮 6") != 0) writeLog("按下了按钮 6");
                ctx.endTreeNode();
            }
            if (ctx.beginTreeNode("测试 3") != 0) {
                _ = ctx.checkbox("复选框 1", &test_checks[0]);
                _ = ctx.checkbox("复选框 2", &test_checks[1]);
                _ = ctx.checkbox("复选框 3", &test_checks[2]);
                ctx.endTreeNode();
            }
            ctx.layoutEndColumn();

            ctx.layoutBeginColumn();
            ctx.layoutRow(1, &.{-1}, 0);
            ctx.text("溪水潺潺，\n倒映蓝天白云。\n微风拂过树梢，\n送来阵阵花香。\n远山如黛，\n令人心旷神怡。");
            ctx.layoutEndColumn();
        }

        // 背景颜色滑块 + 颜色预览
        if (ctx.headerEx("背景颜色", microui.opt_expanded) != 0) {
            ctx.layoutRow(2, &.{ -78, -1 }, 74);
            ctx.layoutBeginColumn();
            ctx.layoutRow(2, &.{ 46, -1 }, 0);
            ctx.label("红:");
            _ = ctx.slider(&bg[0], 0, 255);
            ctx.label("绿:");
            _ = ctx.slider(&bg[1], 0, 255);
            ctx.label("蓝:");
            _ = ctx.slider(&bg[2], 0, 255);
            ctx.layoutEndColumn();
            const r = ctx.layoutNext();
            ctx.drawRect(r, microui.Color.init(@intFromFloat(bg[0]), @intFromFloat(bg[1]), @intFromFloat(bg[2]), 255));
            var buf: [32]u8 = undefined;
            const hex = std.fmt.bufPrint(&buf, "#{X:0>2}{X:0>2}{X:0>2}", .{
                @as(u8, @intFromFloat(bg[0])),
                @as(u8, @intFromFloat(bg[1])),
                @as(u8, @intFromFloat(bg[2])),
            }) catch unreachable;
            ctx.drawControlText(hex, r, .text, microui.opt_align_center);
        }

        ctx.endWindow();
    }
}

fn logWindow(ctx: *microui.Context) void {
    if (ctx.beginWindow("日志窗口", microui.Rect.init(350, 40, 300, 200)) != 0) {
        // 输出面板（占剩余高度）
        ctx.layoutRow(1, &.{-1}, -25);
        ctx.beginPanel("日志输出");
        const panel = ctx.getCurrentContainer();
        ctx.layoutRow(1, &.{-1}, -1);
        ctx.text(log_buf[0..log_len]);
        ctx.endPanel();
        // 有新日志时自动滚动到底部
        if (log_updated) {
            panel.scroll.y = panel.content_size.y;
            log_updated = false;
        }

        // 输入框 + 提交按钮
        var submitted = false;
        ctx.layoutRow(2, &.{ -70, -1 }, 0);
        if ((ctx.textbox(&log_input) & microui.res_submit) != 0) {
            ctx.setFocus(ctx.last_id);
            submitted = true;
        }
        if (ctx.button("提交") != 0) submitted = true;
        if (submitted) {
            writeLog(std.mem.sliceTo(&log_input, 0));
            log_input[0] = 0; // 清空输入框
        }

        ctx.endWindow();
    }
}

fn uint8Slider(ctx: *microui.Context, value: *u8, low: f32, high: f32) void {
    var tmp: f32 = @floatFromInt(value.*);
    // 用 value 指向的实际变量地址做作用域 id：直接取参数地址（&value）会在
    // 同一行连续 4 个滑块（r/g/b/a）时落回相同栈位置，导致 id 相同、焦点串扰
    var value_addr: usize = @intFromPtr(value);
    ctx.pushId(std.mem.asBytes(&value_addr));
    _ = ctx.sliderEx(&tmp, low, high, 0, "{d:.0}", microui.opt_align_center);
    value.* = @intFromFloat(tmp);
    ctx.popId();
}

fn styleWindow(ctx: *microui.Context) void {
    const colors = [_]struct { label: []const u8, id: microui.ColorId }{
        .{ .label = "文字:", .id = .text },
        .{ .label = "边框:", .id = .border },
        .{ .label = "窗口底:", .id = .window_bg },
        .{ .label = "标题底:", .id = .title_bg },
        .{ .label = "标题字:", .id = .title_text },
        .{ .label = "面板底:", .id = .panel_bg },
        .{ .label = "按钮:", .id = .button },
        .{ .label = "按钮悬停:", .id = .button_hover },
        .{ .label = "按钮聚焦:", .id = .button_focus },
        .{ .label = "基础底:", .id = .base },
        .{ .label = "基础悬停:", .id = .base_hover },
        .{ .label = "基础聚焦:", .id = .base_focus },
        .{ .label = "滚动条轨:", .id = .scroll_base },
        .{ .label = "滚动条块:", .id = .scroll_thumb },
    };

    if (ctx.beginWindow("样式编辑器", microui.Rect.init(350, 250, 300, 240)) != 0) {
        const sw = @divTrunc(ctx.getCurrentContainer().body.w * 14, 100);
        ctx.layoutRow(5, &.{ 88, sw, sw, sw, sw }, 0);
        for (colors) |c| {
            const idx = @intFromEnum(c.id);
            ctx.label(c.label);
            uint8Slider(ctx, &ctx.style.colors[idx].r, 0, 255);
            uint8Slider(ctx, &ctx.style.colors[idx].g, 0, 255);
            uint8Slider(ctx, &ctx.style.colors[idx].b, 0, 255);
            uint8Slider(ctx, &ctx.style.colors[idx].a, 0, 255);
        }
        ctx.endWindow();
    }
}

/// 每帧构建 UI 命令列表（在 ctx.begin / ctx.end 之间）
pub fn processFrame(ctx: *microui.Context) void {
    ctx.begin();
    styleWindow(ctx);
    logWindow(ctx);
    testWindow(ctx);
    ctx.end();
}

/// 现代暗色主题：纯样式数据覆盖，核心库零改动。
/// 默认控件高度 = style.size.y + padding*2，这里配成 26px，宽松不逼仄。
/// 窗口底色带一点透明（玻璃感），会透出背景色。
pub fn applyTheme(ctx: *microui.Context) void {
    const s = ctx.style; // ctx.style 是指针，直接取用
    s.size.y = 12;
    s.padding = 7;
    s.spacing = 6;
    s.indent = 16;
    s.title_height = 28;
    s.thumb_size = 10;

    const c = &s.colors;
    c[@intFromEnum(microui.ColorId.text)] = microui.Color.init(232, 235, 242, 255);
    c[@intFromEnum(microui.ColorId.border)] = microui.Color.init(52, 56, 66, 255);
    c[@intFromEnum(microui.ColorId.window_bg)] = microui.Color.init(28, 31, 38, 235);
    c[@intFromEnum(microui.ColorId.title_bg)] = microui.Color.init(20, 22, 28, 245);
    c[@intFromEnum(microui.ColorId.title_text)] = microui.Color.init(210, 216, 228, 255);
    c[@intFromEnum(microui.ColorId.panel_bg)] = microui.Color.init(33, 37, 45, 245);
    c[@intFromEnum(microui.ColorId.button)] = microui.Color.init(52, 58, 70, 255);
    c[@intFromEnum(microui.ColorId.button_hover)] = microui.Color.init(74, 84, 102, 255);
    c[@intFromEnum(microui.ColorId.button_focus)] = microui.Color.init(60, 68, 84, 255);
    c[@intFromEnum(microui.ColorId.base)] = microui.Color.init(20, 23, 29, 255);
    c[@intFromEnum(microui.ColorId.base_hover)] = microui.Color.init(25, 28, 35, 255);
    c[@intFromEnum(microui.ColorId.base_focus)] = microui.Color.init(30, 34, 42, 255);
    c[@intFromEnum(microui.ColorId.scroll_base)] = microui.Color.init(24, 27, 33, 255);
    c[@intFromEnum(microui.ColorId.scroll_thumb)] = microui.Color.init(96, 104, 120, 255);
}
