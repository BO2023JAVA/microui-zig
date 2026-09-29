//! SDL3 + SDL_ttf 的手写 Zig 绑定（Android 用）
//!
//! 为什么不用 @cImport：Zig 0.16 的 cImport 要求模块链接 libc，而 Zig 不自带
//! Android 的 bionic libc（且 NDK 28 新头文件 translate-c 会报错）。
//! 这里只声明本项目用到的 SDL3 / SDL_ttf 符号，结构体布局与 3.4.10 / 3.2.2 头文件一致。
//!
//! 注意：所有指针类型都是 aarch64（Android arm64）下的 8 字节指针布局。

const std = @import("std");

// ===================== 不透明类型 =====================

pub const SDL_Window = opaque {};
pub const SDL_Renderer = opaque {};
pub const SDL_Texture = opaque {};
pub const SDL_IOStream = opaque {};
pub const TTF_Font = opaque {};

// ===================== 基础结构 =====================

/// SDL_Color：RGBA 四通道
pub const SDL_Color = extern struct { r: u8, g: u8, b: u8, a: u8 };

/// SDL_Rect：整数矩形
pub const SDL_Rect = extern struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
};

/// SDL_FRect：浮点矩形
pub const SDL_FRect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// SDL_Surface（只声明用到的开头字段，布局对齐 SDL_surface.h）
/// SDL_Surface（SDL3 3.4.10 布局：flags 与 format 都是 4 字节枚举，无指针间隙）
pub const SDL_Surface = extern struct {
    flags: u32,
    format: u32, // SDL_PixelFormat 枚举（4 字节），不是指针
    w: c_int,
    h: c_int,
    pitch: c_int,
    pixels: ?*anyopaque,
};

// ===================== 事件结构（SDL_events.h，3.4.10） =====================

/// SDL_CommonEvent：所有事件共用前 16 字节
pub const SDL_CommonEvent = extern struct {
    type: u32,
    reserved: u32,
    timestamp: u64,
};

/// SDL_TouchFingerEvent（event.finger.*）——触摸坐标归一化 0..1
pub const SDL_TouchFingerEvent = extern struct {
    type: u32,
    reserved: u32,
    timestamp: u64,
    touch_id: u64,
    finger_id: u64,
    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
    pressure: f32,
    window_id: u32,
};

/// SDL_TextInputEvent（event.text.*）——SDL3 的 text 是指针，UTF-8
pub const SDL_TextInputEvent = extern struct {
    type: u32,
    reserved: u32,
    timestamp: u64,
    window_id: u32,
    text: ?[*:0]const u8,
};

/// SDL_KeyboardEvent（event.key.*）
pub const SDL_KeyboardEvent = extern struct {
    type: u32,
    reserved: u32,
    timestamp: u64,
    window_id: u32,
    which: u32,
    scancode: u32,
    key: u32,
    mod: u16,
    raw: u16,
    down: bool,
    repeat: bool,
};

/// SDL_Event 联合体：只声明本项目用到的成员，_pad 保证 128 字节缓冲
/// （SDL_PollEvent 按 128 字节写入，联合体太小会越界）
pub const SDL_Event = extern union {
    type: u32,
    common: SDL_CommonEvent,
    key: SDL_KeyboardEvent,
    text: SDL_TextInputEvent,
    finger: SDL_TouchFingerEvent,
    _pad: [128]u8,
};

// ===================== 常量（数值取自 3.4.10 头文件） =====================

pub const SDL_INIT_VIDEO: u32 = 0x00000020;
pub const SDL_PIXELFORMAT_RGBA32: u32 = 0x16762004; // 小端 = ABGR8888（内存序 R,G,B,A）
pub const SDL_TEXTUREACCESS_STATIC: c_int = 0;
pub const SDL_TEXTUREACCESS_STREAMING: c_int = 1;
pub const SDL_BLENDMODE_BLEND: c_int = 0x00000001;

pub const SDL_EVENT_QUIT: u32 = 0x100;
pub const SDL_EVENT_KEY_DOWN: u32 = 0x300;
pub const SDL_EVENT_KEY_UP: u32 = 0x301;
pub const SDL_EVENT_TEXT_INPUT: u32 = 0x302;
pub const SDL_EVENT_FINGER_DOWN: u32 = 0x700;
pub const SDL_EVENT_FINGER_UP: u32 = 0x701;
pub const SDL_EVENT_FINGER_MOTION: u32 = 0x702;

pub const SDLK_RETURN: u32 = 0x0d; // '\r'
pub const SDLK_BACKSPACE: u32 = 0x08; // '\b'

// ===================== SDL3 函数 =====================
// 用普通 extern fn（Linux 默认调用约定即 C ABI）。
// 不用 extern "c"：Zig 0.16 要求 extern "c" 链接 libc，而 Android 无现成 libc。

extern fn SDL_Init(flags: u32) bool;
pub const init = SDL_Init;

extern fn SDL_Quit() void;
pub const quit = SDL_Quit;

extern fn SDL_CreateWindowAndRenderer(
    title: [*:0]const u8,
    width: c_int,
    height: c_int,
    window_flags: u32,
    window: *?*SDL_Window,
    renderer: *?*SDL_Renderer,
) bool;
pub const createWindowAndRenderer = SDL_CreateWindowAndRenderer;

extern fn SDL_StartTextInput(window: *SDL_Window) bool;
pub const startTextInput = SDL_StartTextInput;

extern fn SDL_GetWindowSize(window: *SDL_Window, w: *c_int, h: *c_int) bool;
pub const getWindowSize = SDL_GetWindowSize;

extern fn SDL_GetError() [*:0]const u8;
pub const getError = SDL_GetError;

extern fn SDL_SetRenderDrawColor(renderer: *SDL_Renderer, r: u8, g: u8, b: u8, a: u8) bool;
pub const setRenderDrawColor = SDL_SetRenderDrawColor;

extern fn SDL_RenderClear(renderer: *SDL_Renderer) bool;
pub const renderClear = SDL_RenderClear;

extern fn SDL_RenderPresent(renderer: *SDL_Renderer) bool;
pub const renderPresent = SDL_RenderPresent;

extern fn SDL_SetRenderClipRect(renderer: *SDL_Renderer, rect: ?*const SDL_Rect) bool;
pub const setRenderClipRect = SDL_SetRenderClipRect;

extern fn SDL_RenderFillRect(renderer: *SDL_Renderer, rect: ?*const SDL_FRect) bool;
pub const renderFillRect = SDL_RenderFillRect;

extern fn SDL_CreateTexture(
    renderer: *SDL_Renderer,
    format: u32,
    access: c_int,
    w: c_int,
    h: c_int,
) ?*SDL_Texture;
pub const createTexture = SDL_CreateTexture;

extern fn SDL_UpdateTexture(
    texture: *SDL_Texture,
    rect: ?*const SDL_Rect,
    pixels: *const anyopaque,
    pitch: c_int,
) bool;
pub const updateTexture = SDL_UpdateTexture;

extern fn SDL_SetTextureBlendMode(texture: *SDL_Texture, blend_mode: c_int) bool;
pub const setTextureBlendMode = SDL_SetTextureBlendMode;

extern fn SDL_SetTextureColorMod(texture: *SDL_Texture, r: u8, g: u8, b: u8) bool;
pub const setTextureColorMod = SDL_SetTextureColorMod;

extern fn SDL_SetTextureAlphaMod(texture: *SDL_Texture, a: u8) bool;
pub const setTextureAlphaMod = SDL_SetTextureAlphaMod;

extern fn SDL_RenderTexture(
    renderer: *SDL_Renderer,
    texture: *SDL_Texture,
    srcrect: ?*const SDL_FRect,
    dstrect: ?*const SDL_FRect,
) bool;
pub const renderTexture = SDL_RenderTexture;

extern fn SDL_DestroyTexture(texture: *SDL_Texture) void;
pub const destroyTexture = SDL_DestroyTexture;

extern fn SDL_DestroyRenderer(renderer: *SDL_Renderer) void;
pub const destroyRenderer = SDL_DestroyRenderer;

extern fn SDL_DestroyWindow(window: *SDL_Window) void;
pub const destroyWindow = SDL_DestroyWindow;

extern fn SDL_PollEvent(event: ?*SDL_Event) bool;
pub const pollEvent = SDL_PollEvent;

extern fn SDL_IOFromConstMem(mem: *const anyopaque, size: usize) ?*SDL_IOStream;
pub const ioFromConstMem = SDL_IOFromConstMem;

extern fn SDL_DestroySurface(surface: *SDL_Surface) void;
pub const destroySurface = SDL_DestroySurface;

// ===================== SDL_ttf 3.2.2 函数 =====================

extern fn TTF_Init() bool;
pub const ttf_init = TTF_Init;

extern fn TTF_OpenFontIO(src: *SDL_IOStream, close_io: bool, ptsize: f32) ?*TTF_Font;
pub const ttf_open_font_io = TTF_OpenFontIO;

extern fn TTF_CloseFont(font: *TTF_Font) void;
pub const ttf_close_font = TTF_CloseFont;

extern fn TTF_Quit() void;
pub const ttf_quit = TTF_Quit;

extern fn TTF_GetGlyphMetrics(
    font: *TTF_Font,
    ch: u32,
    minx: *c_int,
    maxx: *c_int,
    miny: *c_int,
    maxy: *c_int,
    advance: ?*c_int,
) bool;
pub const ttf_get_glyph_metrics = TTF_GetGlyphMetrics;

extern fn TTF_RenderGlyph_Blended(font: *TTF_Font, ch: u32, fg: SDL_Color) ?*SDL_Surface;
pub const ttf_render_glyph_blended = TTF_RenderGlyph_Blended;

/// 取 SDL 错误信息（只在 Debug 构建打印用）
pub fn errorString() []const u8 {
    return std.mem.span(getError());
}

// ===================== Android logcat 日志（诊断用） =====================

extern fn __android_log_print(prio: c_int, tag: [*:0]const u8, fmt: [*:0]const u8, ...) c_int;

/// 往 logcat 写一行日志（tag = "ZigDemo"，`adb logcat -s ZigDemo` 查看）
pub fn logMsg(msg: []const u8) void {
    var buf: [256]u8 = undefined;
    const n = @min(msg.len, buf.len - 1);
    @memcpy(buf[0..n], msg[0..n]);
    buf[n] = 0;
    _ = __android_log_print(3, "ZigDemo", "%s", @as([*:0]const u8, @ptrCast(&buf)));
}
