# microui — A Tiny Immediate-Mode GUI Library (Zig)

**English** | [中文](README.md)

microui is a tiny immediate-mode GUI library. This is a **complete Zig rewrite** of
[rxi/microui](https://github.com/rxi/microui), with Chinese text rendering added.

**Design goals: minimal · complete · clean · tidy · simple**

- **Zero heap allocation**: all state lives in fixed-size arrays; the core is a single
  dependency-free file.
- **Immediate mode**: rebuild the UI every frame by calling widgets; cross-frame state
  is retained via IDs and object pools — no widget tree, no messages.
- **Frontend/backend separation**: the library only emits a *draw command list*; the host
  does the actual rendering (OpenGL / SDL / software).
- **Chinese support**: the demo rasterizes CJK glyphs on demand from the system font via
  Windows GDI — type and display Chinese out of the box.

## Layout

```
microui/
├── build.zig          # Build script (Win x64 demo + Android arm64 shared lib)
├── LICENSE            # MIT
├── README.md          # Chinese docs
├── README.en.md       # This file
├── android/           # Android packaging (Gradle; prebuilt .so → APK)
└── src/
    ├── microui.zig          # ★ Core library (frontend: single file, no deps, zero-alloc)
    ├── renderer.zig         # SDL3 render backend (desktop Windows x64, GDI CJK glyphs)
    ├── renderer_android.zig # Android render backend (SDL3 + SDL_ttf CJK glyphs)
    ├── sdl3_android.zig     # Hand-written SDL3/SDL_ttf bindings (Android, no @cImport)
    ├── main_android.zig     # Android entry (exports SDL_main + touch→mouse mapping)
    ├── app.zig              # Sample UI content (platform-agnostic, shared)
    ├── demo.zig             # Desktop entry (SDL event loop + input mapping)
    ├── atlas.zig            # Atlas data (ASCII glyphs + icons)
    └── font_simhei.ttf      # Embedded CJK font (Android glyph rasterization)
```

## Building

### Prerequisites

| Dependency | Notes |
|---|---|
| [Zig 0.16](https://ziglang.org/download/) | The only required toolchain |
| SDL3 (include / lib / bin) | Only for the demo; the core library does not need it |

> The library itself has no dependencies — copy `src/microui.zig` into any project.
> Only `demo.zig` (the sample render backend) uses SDL3.

### Build & run the demo

```bash
# Compile and run (Debug — runtime safety checks, for development)
zig build run

# ReleaseSmall build (size-optimized, ~300 KB)
zig build -Doptimize=ReleaseSmall run

# Point at a custom SDL3 root
zig build -Dsdl=C:/path/to/SDL3 -Doptimize=ReleaseSmall run
```

Output goes to `zig-out/bin/` (`microui-demo.exe` + `SDL3.dll`); SDL3.dll is copied there
automatically.

> On Windows the demo rasterizes CJK glyphs from system fonts (Microsoft YaHei / SimSun)
> via GDI, so the text box accepts Chinese input directly. On other platforms, replace the
> font-rasterization code in `demo.zig` with your own.

### Android (arm64-v8a)

Prereqs: Android SDK + NDK 28.2 + CMake + JDK 17+ (paths in `build.zig` and `android/`).

```bash
# One-step prep: cross-compile SDL3/SDL_ttf + build the app .so, copy into app/libs/arm64-v8a/
# (first time: download SDL3/SDL_ttf sources and put freetype into SDL3_ttf/external/freetype;
#  paths are script parameters)
powershell -ExecutionPolicy Bypass -File android/prepare_libs.ps1

# Package the APK (JAVA_HOME → JDK 17+; GRADLE_USER_HOME can point at a local gradle cache)
cd android && gradlew.bat assembleDebug   # debug-signed, installable
#    or gradlew.bat assembleRelease        # release (signed via android/keystore.properties)
#      artifact: android/app/build/outputs/apk/release/app-release.apk

# Install on a device (USB debugging enabled)
adb install app/build/outputs/apk/debug/app-debug.apk
```

Android notes:

- **Touch acts as mouse**: single-finger down/move/up map to the left mouse button
  (`main_android.zig`); scrollbars are draggable directly.
- **Chinese input**: SDL3 delivers the IME text as `SDL_EVENT_TEXT_INPUT` on Android,
  so the text box works as-is.
- **CJK glyphs**: `renderer_android.zig` rasterizes with SDL_ttf (FreeType) from an embedded
  font. `src/font_simhei.ttf` in the repo is a **subset** (104 KB, covers the demo's
  characters; regenerate with `python -m fontTools.subset <font> --text-file=<chars> --output-file=src/font_simhei.ttf`).
  Swap in a full font (e.g. Microsoft YaHei) and rebuild to support arbitrary input.
- **Hand-written SDL bindings**: `src/sdl3_android.zig` declares the needed SDL3/SDL_ttf
  symbols manually (no @cImport) — Zig 0.16's cImport requires linking libc, and Zig ships
  no bionic for Android, so the symbols are declared directly.
- **The three .so are not committed**: `android/app/libs/` is gitignored; regenerate with
  `prepare_libs.ps1`.

## Using the library in your project

The core is **single-file, dependency-free, zero-alloc**. Two ways to integrate:

### Option A: copy the file

Copy `src/microui.zig` and `@import("microui.zig")`.

### Option B: as a Zig module (recommended)

In your `build.zig`:

```zig
const microui_mod = b.createModule(.{
    .root_source_file = b.path("path/to/microui.zig"),
    .target = target,
    .optimize = optimize,
});
// exe.root_module.addImport("microui", microui_mod);
```

### Minimal integration steps

The host implements three things:

1. **Two measurement callbacks**: `text_width` / `text_height`;
2. **Per-frame flow**: `ctx.begin()` → windows/widgets → `ctx.end()`;
3. **Render the commands**: after `end()`, iterate with `commandIter()` and draw each one — or just use the bundled SDL3 backend (`renderer.zig`, one call `renderer.render(ctx)`).

```zig
const microui = @import("microui");

var ctx: microui.Context = undefined;
microui.Context.init(&ctx);
ctx.text_width = myTextWidth;   // fn(ctx, str) i32
ctx.text_height = myTextHeight; // fn(ctx) i32

// Every frame:
ctx.begin();
if (ctx.beginWindow("Main", microui.Rect.init(40, 40, 300, 200)) != 0) {
    if (ctx.button("OK") != 0) { /* clicked */ }
    _ = ctx.slider(&value, 0, 100);
    ctx.endWindow();
}
ctx.end();

// Draw commands:
var it = ctx.commandIter();
while (it.next()) |cmd| {
    switch (cmd) {
        .text => |t| myDrawText(t.str[0..t.len], t.pos, t.color),
        .rect => |r| myDrawRect(r.rect, r.color),
        .icon => |ic| myDrawIcon(ic.id, ic.rect, ic.color),
        .clip => |c| mySetClip(c),
        else => {},
    }
}
```

See `src/renderer.zig` for a complete SDL3 Render API backend (including CJK glyph rasterization).

## API Reference

### Types

| Type | Description |
|---|---|
| `Vec2` | `{ x: i32, y: i32 }` |
| `Rect` | `{ x, y, w, h: i32 }`; `Rect.init(x, y, w, h)` |
| `Color` | `{ r, g, b, a: u8 }`; `Color.init(r, g, b, a)` |
| `Id` | `u32` widget ID (hash of content; keeps state across frames) |
| `Real` | `f32` float type for numeric widgets |
| `Command` | Draw-command union (`jump/clip/rect/icon/text`) |
| `CommandIter` | Command iterator; `.next() -> ?Command` |
| `Context` | Global context (all UI state) |
| `Style` | Styling (sizes, padding, spacing, color array) |
| `Layout` / `Container` / `PoolItem` / `TextCommand` | Internal data structures |

### Constants

| Category | Constants |
|---|---|
| Result flags | `res_active` `res_submit` `res_change` |
| Widget options | `opt_align_center` `opt_align_right` `opt_no_interact` `opt_no_frame` `opt_no_resize` `opt_no_scroll` `opt_no_close` `opt_no_title` `opt_hold_focus` `opt_auto_size` `opt_popup` `opt_closed` `opt_expanded` |
| Mouse | `mouse_left` `mouse_right` `mouse_middle` |
| Keys | `key_shift` `key_ctrl` `key_alt` `key_backspace` `key_return` |
| Clip | `clip_part` `clip_all` |
| Color IDs | `ColorId.text .border .window_bg .title_bg .title_text .panel_bg .button .button_hover .button_focus .base .base_hover .base_focus .scroll_base .scroll_thumb` |
| Icon IDs | `Icon.close(1) .check(2) .expanded(3) .collapsed(4)` |
| Capacities | `command_cap(1024)` `text_cap(128)` `max_fmt(64)` etc. (see top of source) |

### Context methods

#### Lifecycle

| Method | Description |
|---|---|
| `init(ctx)` | Initialize (zeroed + default style) |
| `begin(ctx)` | Start a frame (clear commands, compute input deltas) |
| `end(ctx)` | End a frame (scroll/focus handling, command jumps) |
| `setFocus(ctx, id)` | Set focused widget |

#### ID system

| Method | Description |
|---|---|
| `getId(ctx, data)` | Stable 32-bit ID from content |
| `pushId(ctx, data)` / `popId(ctx)` | Local ID scope |

#### Clipping

| Method | Description |
|---|---|
| `pushClipRect(ctx, rect)` | Push clip rect (intersected with current) |
| `popClipRect(ctx)` | Pop clip rect |
| `getClipRect(ctx)` | Get current clip rect |
| `checkClip(ctx, r)` | `0` visible / `clip_part` partial / `clip_all` hidden |

#### Containers

| Method | Description |
|---|---|
| `getCurrentContainer(ctx)` | Current window/panel container |
| `bringToFront(ctx, cnt)` | Bring container to front |

#### Input (call before `begin` each frame)

| Method | Description |
|---|---|
| `inputMouseMove(ctx, x, y)` | Mouse move |
| `inputMouseDown(ctx, x, y, btn)` | Mouse down |
| `inputMouseUp(ctx, x, y, btn)` | Mouse up |
| `inputScroll(ctx, x, y)` | Scroll wheel |
| `inputKeyDown(ctx, key)` / `inputKeyUp(ctx, key)` | Keyboard |
| `inputText(ctx, text)` | UTF-8 text input (text box) |

#### Draw commands

| Method | Description |
|---|---|
| `commandIter(ctx)` | Create a command iterator |
| `setClip(ctx, rect)` | Record a clip command |
| `drawRect(ctx, rect, color)` | Record a filled rect |
| `drawBox(ctx, rect, color)` | Record a border box |
| `drawText(ctx, str, pos, color)` | Record text |
| `drawIcon(ctx, id, rect, color)` | Record an icon |

#### Layout

| Method | Description |
|---|---|
| `layoutRow(ctx, items, widths, height)` | Start a row (`widths` null = reuse; negative = fill) |
| `layoutWidth(ctx, w)` / `layoutHeight(ctx, h)` | Size of the next widget |
| `layoutBeginColumn(ctx)` / `layoutEndColumn(ctx)` | Column (sub-layout) |
| `layoutSetNext(ctx, r, relative)` | Exact rect for the next widget |
| `layoutNext(ctx)` | Next widget rect (call once per widget) |

#### Widget internals

| Method | Description |
|---|---|
| `drawControlFrame(ctx, id, rect, colorid, opt)` | Widget background (hover/focus tint) |
| `drawControlText(ctx, str, rect, colorid, opt)` | Text inside a widget rect |
| `mouseOver(ctx, rect)` | Is the mouse over the rect |
| `updateControl(ctx, id, rect, opt)` | Hover/focus state machine |

#### Widgets (return `u8` flags; test with `&`)

| Method | Description | Returns |
|---|---|---|
| `text(ctx, str)` | Wrapped text block | — |
| `label(ctx, str)` | One-line label | — |
| `button(ctx, label)` / `buttonEx(ctx, label, icon, opt)` | Button | `res_submit` |
| `checkbox(ctx, label, state)` | Checkbox (toggles `*bool`) | `res_change` |
| `textbox(ctx, buf)` / `textboxEx(ctx, buf, opt)` | Text box (UTF-8, Enter submits) | `res_submit` / `res_change` |
| `slider(ctx, value, low, high)` / `sliderEx(ctx, value, low, high, step, fmt, opt)` | Slider (Shift+click types) | `res_change` |
| `number(ctx, value, step)` / `numberEx(ctx, value, step, fmt, opt)` | Drag-number | `res_change` |
| `header(ctx, label)` / `headerEx(ctx, label, opt)` | Collapsible header | `res_active` |
| `beginTreeNode(ctx, label)` / `beginTreeNodeEx(ctx, label, opt)` / `endTreeNode(ctx)` | Tree node | `res_active` |

#### Windows / panels

| Method | Description |
|---|---|
| `beginWindow(ctx, title, rect)` / `beginWindowEx(ctx, title, rect, opt)` | Begin window (title/close/drag/resize) |
| `endWindow(ctx)` | End window |
| `openPopup(ctx, name)` | Open popup at the mouse |
| `beginPopup(ctx, name)` / `endPopup(ctx)` | Popup (closes on outside click) |
| `beginPanel(ctx, name)` / `beginPanelEx(ctx, name, opt)` / `endPanel(ctx)` | Embedded panel |

### Callbacks (Context fields, implemented by the host)

| Field | Signature | Notes |
|---|---|---|
| `text_width` | `fn(ctx, str: []const u8) i32` | **Required**: measure text width |
| `text_height` | `fn(ctx) i32` | **Required**: line height |
| `draw_frame` | `fn(ctx, rect, colorid) void` | Optional: widget background (default fills + borders) |

## License

[MIT](LICENSE). This project is a Zig rewrite of [rxi/microui](https://github.com/rxi/microui) (MIT).
