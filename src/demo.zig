//! microui 演示程序 —— 桌面（Windows x64）入口
//!
//! 只负责平台侧的事：SDL 事件 → microui 输入、渲染后端调用。
//! 界面内容（三个示例窗口）在 app.zig，与平台无关。

const std = @import("std");
const sdl = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL3/SDL.h");
});
const microui = @import("microui");
const renderer = @import("renderer");
const app = @import("app");

// ===================== 输入映射 =====================

fn mapButton(b: u8) u8 {
    return switch (b) {
        sdl.SDL_BUTTON_LEFT => microui.mouse_left,
        sdl.SDL_BUTTON_RIGHT => microui.mouse_right,
        sdl.SDL_BUTTON_MIDDLE => microui.mouse_middle,
        else => 0,
    };
}

fn mapKey(k: u32) u8 {
    return switch (k) {
        sdl.SDLK_LSHIFT, sdl.SDLK_RSHIFT => microui.key_shift,
        sdl.SDLK_LCTRL, sdl.SDLK_RCTRL => microui.key_ctrl,
        sdl.SDLK_LALT, sdl.SDLK_RALT => microui.key_alt,
        sdl.SDLK_RETURN => microui.key_return,
        sdl.SDLK_BACKSPACE => microui.key_backspace,
        else => 0,
    };
}

// ===================== 主程序 =====================

pub fn main() !void {
    renderer.init();
    defer renderer.deinit();

    var ctx: microui.Context = undefined;
    microui.Context.init(&ctx);
    app.applyTheme(&ctx); // 覆盖默认样式为现代暗色主题
    ctx.text_width = renderer.textWidth;
    ctx.text_height = renderer.textHeight;

    // 主循环
    while (true) {
        var e: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&e)) {
            switch (e.type) {
                sdl.SDL_EVENT_QUIT => return,
                sdl.SDL_EVENT_MOUSE_MOTION => ctx.inputMouseMove(@intFromFloat(e.motion.x), @intFromFloat(e.motion.y)),
                sdl.SDL_EVENT_MOUSE_WHEEL => ctx.inputScroll(0, @intFromFloat(e.wheel.y * -30)),
                sdl.SDL_EVENT_TEXT_INPUT => ctx.inputText(std.mem.span(@as([*:0]const u8, @ptrCast(e.text.text)))),
                sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
                    const b = mapButton(e.button.button);
                    if (b != 0) {
                        if (e.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN) {
                            ctx.inputMouseDown(@intFromFloat(e.button.x), @intFromFloat(e.button.y), b);
                        } else {
                            ctx.inputMouseUp(@intFromFloat(e.button.x), @intFromFloat(e.button.y), b);
                        }
                    }
                },
                sdl.SDL_EVENT_KEY_DOWN, sdl.SDL_EVENT_KEY_UP => {
                    const k = mapKey(e.key.key);
                    if (k != 0) {
                        if (e.type == sdl.SDL_EVENT_KEY_DOWN) ctx.inputKeyDown(k) else ctx.inputKeyUp(k);
                    }
                },
                else => {},
            }
        }

        // 处理一帧：构建 UI 命令列表
        app.processFrame(&ctx);

        // 渲染：清屏后由后端遍历命令列表绘制
        renderer.begin(microui.Color.init(@intFromFloat(app.bg[0]), @intFromFloat(app.bg[1]), @intFromFloat(app.bg[2]), 255));
        renderer.render(&ctx);
        renderer.end();
    }
}
