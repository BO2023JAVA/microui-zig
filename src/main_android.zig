//! microui 演示程序 —— Android 入口
//!
//! SDLActivity 加载 libmicrozig.so（getLibraries() 里 "microzig"）并调用导出的 SDL_main。
//! 职责只比桌面版多一件事：把触摸事件（FINGER_*）映射成 microui 的鼠标输入，
//! 因为 Android 没有鼠标。界面内容在 app.zig，与桌面版共用。
//! SDL 调用走 sdl3_android.zig 的手写绑定。

const std = @import("std");
const microui = @import("microui");
const renderer = @import("renderer");
const app = @import("app");
const sdl = @import("sdl3_android");

/// Android 触摸坐标是归一化的（0..1），换算成窗口像素坐标
fn fingerToPixels(x: f32, y: f32) struct { ix: i32, iy: i32 } {
    const sz = renderer.windowSize();
    return .{
        .ix = @intFromFloat(x * @as(f32, @floatFromInt(sz[0]))),
        .iy = @intFromFloat(y * @as(f32, @floatFromInt(sz[1]))),
    };
}

/// SDLActivity 的 getLibraries() 依次加载 "SDL3"、"SDL3_ttf"、"microzig"，
/// 库名与加载顺序需与 android 工程里的 SDLActivity.java 保持一致。

/// 当前跟踪的手指 ID：只认第一个按下的手指，后续手指（误触/多指）忽略，
/// 避免第二个手指按下导致鼠标位置跳变、窗口瞬间"飞"过去
var active_finger: ?u64 = null;

export fn SDL_main(argc: c_int, argv: [*][*:0]u8) c_int {
    _ = argc;
    _ = argv;

    renderer.init();
    defer renderer.deinit();

    var ctx: microui.Context = undefined;
    microui.Context.init(&ctx);
    app.applyTheme(&ctx);
    ctx.text_width = renderer.textWidth;
    ctx.text_height = renderer.textHeight;

    // 主循环：Android 由 SDLActivity 驱动，SDL_PollEvent 返回触摸/按键/输入法事件
    while (true) {
        var e: sdl.SDL_Event = undefined;
        while (sdl.pollEvent(&e)) {
            switch (e.type) {
                sdl.SDL_EVENT_QUIT => return 0,
                sdl.SDL_EVENT_FINGER_DOWN => {
                    // 无条件接管跟踪：模拟器/设备可能丢失 UP 或 finger_id 不稳定，
                    // 若死守"已有手指则忽略"，状态会永久卡在按下，界面无法再点击
                    active_finger = e.finger.finger_id;
                    const p = fingerToPixels(e.finger.x, e.finger.y);
                    ctx.inputMouseDown(p.ix, p.iy, microui.mouse_left);
                },
                sdl.SDL_EVENT_FINGER_MOTION => {
                    // 只跟随正在跟踪的手指
                    const f = active_finger orelse continue;
                    if (f != e.finger.finger_id) continue;
                    const p = fingerToPixels(e.finger.x, e.finger.y);
                    ctx.inputMouseMove(p.ix, p.iy);
                },
                sdl.SDL_EVENT_FINGER_UP => {
                    // 无条件释放：不依赖 UP 与 DOWN 的 finger_id 匹配，
                    // 否则 UP 被忽略会导致 mouse_down 粘滞、窗口一直跟随移动
                    if (active_finger == null) continue;
                    active_finger = null;
                    const p = fingerToPixels(e.finger.x, e.finger.y);
                    ctx.inputMouseUp(p.ix, p.iy, microui.mouse_left);
                },
                // SDL3 在 Android 上会把输入法（IME）文本发成 TEXT_INPUT，输入框直接用
                sdl.SDL_EVENT_TEXT_INPUT => ctx.inputText(std.mem.span(e.text.text orelse continue)),
                sdl.SDL_EVENT_KEY_DOWN, sdl.SDL_EVENT_KEY_UP => {
                    // 常用键：回车提交 / 退格删除
                    if (e.key.key == sdl.SDLK_RETURN) {
                        if (e.type == sdl.SDL_EVENT_KEY_DOWN) ctx.inputKeyDown(microui.key_return);
                    } else if (e.key.key == sdl.SDLK_BACKSPACE) {
                        if (e.type == sdl.SDL_EVENT_KEY_DOWN) ctx.inputKeyDown(microui.key_backspace);
                    }
                },
                else => {},
            }
        }

        // 处理一帧：构建 UI 命令列表（与桌面版共用）
        app.processFrame(&ctx);

        // 每帧兜底开启文本输入（幂等）：保证点击输入框时输入法（IME）已可用
        renderer.ensureTextInput();

        // 渲染：清屏后由后端遍历命令列表绘制
        renderer.begin(microui.Color.init(@intFromFloat(app.bg[0]), @intFromFloat(app.bg[1]), @intFromFloat(app.bg[2]), 255));
        renderer.render(&ctx);
        renderer.end();
    }
}
