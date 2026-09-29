# microui — 极简即时模式 UI 库（Zig）

[English](README.en.md) | **中文**

microui 是一个极小的即时模式（immediate-mode）GUI 库，这是 rxi/microui 的 **Zig 完整重写版**，并新增了中文渲染支持。

**设计理念：极小 · 完备 · 整洁 · 干净 · 简单**

- **零堆分配**：所有状态使用固定容量数组，核心单文件，不依赖第三方库；
- **即时模式**：每帧调用控件函数重建界面，跨帧状态靠 ID + 对象池保留，无需控件对象树；
- **前后端分离**：库只生成"绘制命令列表"，渲染完全由宿主实现（OpenGL / SDL / 软件绘制皆可）；
- **中文支持**：演示程序内置 Windows GDI 动态字形栅格化，中文、英文混排开箱即用。

## 目录结构

```
microui/
├── build.zig          # 构建脚本（Win x64 演示 + Android arm64 动态库）
├── LICENSE            # MIT 许可证
├── README.md          # 本文档（中文）
├── README.en.md       # English version
├── android/           # Android 打包工程（Gradle，预编译 .so → APK）
└── src/
    ├── microui.zig          # ★ 核心库（前端：单文件、无依赖、零堆分配）
    ├── renderer.zig         # SDL3 渲染后端（桌面 Windows x64，GDI 中文字形）
    ├── renderer_android.zig # Android 渲染后端（SDL3 + SDL_ttf 中文字形）
    ├── sdl3_android.zig     # SDL3/SDL_ttf 手写绑定（Android 用，无 @cImport）
    ├── main_android.zig     # Android 入口（导出 SDL_main + 触摸→鼠标映射）
    ├── app.zig              # 示例 UI 内容（平台无关，桌面/安卓共用）
    ├── demo.zig             # 桌面入口（SDL 事件循环 + 输入映射）
    ├── atlas.zig            # 图集数据（ASCII 字形 + 图标）
    └── font_simhei.ttf      # 内嵌中文字体（Android 字形栅格化）
```

## 构建

### 前置条件

| 依赖 | 说明 |
|---|---|
| [Zig 0.16](https://ziglang.org/download/) | 唯一必需的工具链 |
| SDL3（含 include / lib / bin） | 仅演示程序需要；核心库不依赖 |

> 库本身不需要 SDL——`src/microui.zig` 可以单独拷贝进任何项目。只有 `demo.zig`（渲染后端示例）用到 SDL3。

### 构建并运行演示

```bash
# 编译并运行（Debug，带运行时安全检查，适合开发）
zig build run

# 编译 ReleaseSmall（体积优先，约 300KB）
zig build -Doptimize=ReleaseSmall run

# 若 SDL3 不在默认路径，用 -Dsdl= 指定根目录
zig build -Dsdl=C:/path/to/SDL3 -Doptimize=ReleaseSmall run
```

产物输出到 `zig-out/bin/`（`microui-demo.exe` + `SDL3.dll`），SDL3.dll 会自动拷贝到输出目录。

> 演示程序在 Windows 上用 GDI 读取系统字体（微软雅黑 / 宋体）栅格化中文字形，
> 文本框可直接输入中文。其他平台需自行替换 `demo.zig` 中的字体栅格化逻辑。

### Android（arm64-v8a）

前置：Android SDK + NDK 28.2 + CMake + JDK 17+（对应路径见 `build.zig` 与 `android/`）。

```bash
# 一步准备：交叉编译 SDL3/SDL_ttf + 构建应用 .so，拷贝到 app/libs/arm64-v8a/
# （首次需下载 SDL3/SDL_ttf 源码并在 SDL3_ttf/external/freetype 放入 freetype，路径见脚本参数）
powershell -ExecutionPolicy Bypass -File android/prepare_libs.ps1

# 打包 APK（JAVA_HOME 指向 JDK17+，GRADLE_USER_HOME 可指向本地 gradle 缓存）
cd android && gradlew.bat assembleDebug   # debug 签名，可直接安装
#   或 gradlew.bat assembleRelease        # release（用 android/keystore.properties 的签名）
#      产物：android/app/build/outputs/apk/release/app-release.apk

# 安装到真机（需开启 USB 调试）
adb install app/build/outputs/apk/debug/app-debug.apk
```

Android 端要点：

- **触摸即鼠标**：单指按下/移动/抬起映射为鼠标左键（`main_android.zig`），滚动条可直接拖动；
- **中文输入**：SDL3 在 Android 上把输入法（IME）文本发成 `SDL_EVENT_TEXT_INPUT`，输入框直接可用；
- **中文字形**：`renderer_android.zig` 用 SDL_ttf（FreeType）从内嵌字体栅格化。仓库里的
  `src/font_simhei.ttf` 是**子集字体**（104KB，仅含 demo 用到的字符，运行时子集化生成：
  `python -m fontTools.subset 原字体 --text-file=字符表 --output-file=src/font_simhei.ttf`）。
  如需支持任意中文输入，用完整字体（如微软雅黑）替换该文件后重新编译；
- **手写 SDL 绑定**：`src/sdl3_android.zig` 是手写的 SDL3/SDL_ttf 绑定（无 @cImport）——
  Zig 0.16 的 cImport 要求链接 libc，而 Zig 不自带 Android 的 bionic，故直接声明所需符号；
- **三个 .so 不进仓库**：`android/app/libs/` 已在 .gitignore，用 `prepare_libs.ps1` 现编。

## 在自己的项目中使用

核心库是**单文件、零依赖、无堆分配**的，有两种接入方式：

### 方式一：直接拷贝

把 `src/microui.zig` 拷进项目，`@import("microui.zig")` 即可。

### 方式二：作为模块（推荐）

在 `build.zig` 中：

```zig
const microui_mod = b.createModule(.{
    .root_source_file = b.path("path/to/microui.zig"),
    .target = target,
    .optimize = optimize,
});
// 在你的可执行/库模块里导入：
// exe.root_module.addImport("microui", microui_mod);
```

### 最小集成步骤

宿主（你的代码）需要做三件事：

1. **实现两个测量回调**：`text_width` / `text_height`（库要知道文字占多大）；
2. **每帧流程**：`ctx.begin()` → 调用窗口/控件 → `ctx.end()`；
3. **渲染命令**：`ctx.end()` 后用 `commandIter()` 遍历命令列表，逐条绘制——或直接使用附带的 SDL3 后端（`renderer.zig`，`renderer.render(ctx)` 一步完成）。

```zig
const microui = @import("microui");

var ctx: microui.Context = undefined;
microui.Context.init(&ctx);
ctx.text_width = myTextWidth;   // fn(ctx, str) i32
ctx.text_height = myTextHeight; // fn(ctx) i32

// 每帧：
ctx.begin();
if (ctx.beginWindow("主窗口", microui.Rect.init(40, 40, 300, 200)) != 0) {
    if (ctx.button("按钮") != 0) { /* 被点击 */ }
    _ = ctx.slider(&value, 0, 100);
    ctx.endWindow();
}
ctx.end();

// 渲染命令列表（示例：分发到自己的绘制函数）
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

完整渲染后端示例见 `src/renderer.zig`（SDL3 Render API 实现，含中文字形栅格化）。

## API 参考

### 类型

| 类型 | 说明 |
|---|---|
| `Vec2` | `{ x: i32, y: i32 }` 二维向量 |
| `Rect` | `{ x, y, w, h: i32 }` 矩形；`Rect.init(x, y, w, h)` |
| `Color` | `{ r, g, b, a: u8 }` 颜色；`Color.init(r, g, b, a)` |
| `Id` | `u32` 控件 ID（内容哈希，跨帧保留状态用） |
| `Real` | `f32` 数字控件浮点类型 |
| `Command` | 绘制命令联合体（`jump/clip/rect/icon/text`） |
| `CommandIter` | 命令遍历器，`.next() -> ?Command` |
| `Context` | 全局上下文（全部 UI 状态） |
| `Style` | 样式（尺寸、内边距、间距、配色数组） |
| `Layout` / `Container` / `PoolItem` / `TextCommand` | 内部数据结构 |

### 常量

| 分类 | 常量 |
|---|---|
| 返回标志 | `res_active` `res_submit` `res_change` |
| 控件选项 | `opt_align_center` `opt_align_right` `opt_no_interact` `opt_no_frame` `opt_no_resize` `opt_no_scroll` `opt_no_close` `opt_no_title` `opt_hold_focus` `opt_auto_size` `opt_popup` `opt_closed` `opt_expanded` |
| 鼠标 | `mouse_left` `mouse_right` `mouse_middle` |
| 键盘 | `key_shift` `key_ctrl` `key_alt` `key_backspace` `key_return` |
| 裁剪 | `clip_part` `clip_all` |
| 颜色 ID | `ColorId.text .border .window_bg .title_bg .title_text .panel_bg .button .button_hover .button_focus .base .base_hover .base_focus .scroll_base .scroll_thumb` |
| 图标 ID | `Icon.close(1) .check(2) .expanded(3) .collapsed(4)` |
| 容量 | `command_cap(1024)` `text_cap(128)` `max_fmt(64)` 等（见源码顶部） |

### Context 方法

#### 生命周期

| 方法 | 说明 |
|---|---|
| `init(ctx)` | 初始化（置零 + 默认样式） |
| `begin(ctx)` | 开始一帧（清空命令、计算输入增量） |
| `end(ctx)` | 结束一帧（处理滚动/焦点、整理命令跳转链） |
| `setFocus(ctx, id)` | 设置焦点控件 |

#### ID 系统

| 方法 | 说明 |
|---|---|
| `getId(ctx, data)` | 由内容计算稳定 32 位 ID |
| `pushId(ctx, data)` / `popId(ctx)` | 局部 ID 作用域 |

#### 裁剪

| 方法 | 说明 |
|---|---|
| `pushClipRect(ctx, rect)` | 压入裁剪矩形（与当前求交集） |
| `popClipRect(ctx)` | 弹出裁剪矩形 |
| `getClipRect(ctx)` | 获取当前裁剪矩形 |
| `checkClip(ctx, r)` | 裁剪检测：`0` 可见 / `clip_part` 部分 / `clip_all` 不可见 |

#### 容器

| 方法 | 说明 |
|---|---|
| `getCurrentContainer(ctx)` | 当前容器（窗口/面板） |
| `bringToFront(ctx, cnt)` | 容器置顶 |

#### 输入（每帧 begin 之前调用）

| 方法 | 说明 |
|---|---|
| `inputMouseMove(ctx, x, y)` | 鼠标移动 |
| `inputMouseDown(ctx, x, y, btn)` | 鼠标按下 |
| `inputMouseUp(ctx, x, y, btn)` | 鼠标抬起 |
| `inputScroll(ctx, x, y)` | 滚轮 |
| `inputKeyDown(ctx, key)` / `inputKeyUp(ctx, key)` | 键盘 |
| `inputText(ctx, text)` | UTF-8 文本输入（文本框） |

#### 绘制命令（生成命令列表）

| 方法 | 说明 |
|---|---|
| `commandIter(ctx)` | 创建命令遍历器 |
| `setClip(ctx, rect)` | 记录裁剪命令 |
| `drawRect(ctx, rect, color)` | 记录填充矩形 |
| `drawBox(ctx, rect, color)` | 记录边框矩形 |
| `drawText(ctx, str, pos, color)` | 记录文本 |
| `drawIcon(ctx, id, rect, color)` | 记录图标 |

#### 布局

| 方法 | 说明 |
|---|---|
| `layoutRow(ctx, items, widths, height)` | 开始一行（widths 为 null 沿用上次；负数=填充剩余） |
| `layoutWidth(ctx, w)` / `layoutHeight(ctx, h)` | 指定下一个控件尺寸 |
| `layoutBeginColumn(ctx)` / `layoutEndColumn(ctx)` | 列布局（子布局） |
| `layoutSetNext(ctx, r, relative)` | 指定下一个控件的精确矩形 |
| `layoutNext(ctx)` | 取得下一个控件矩形（每个控件调用一次） |

#### 控件基础

| 方法 | 说明 |
|---|---|
| `drawControlFrame(ctx, id, rect, colorid, opt)` | 控件底色（悬停/聚焦自动变色） |
| `drawControlText(ctx, str, rect, colorid, opt)` | 控件内文字（居中/右对齐/裁剪） |
| `mouseOver(ctx, rect)` | 鼠标是否悬停 |
| `updateControl(ctx, id, rect, opt)` | 更新悬停/焦点状态机 |

#### 控件（返回 `u8` 标志，`&` 检测）

| 方法 | 说明 | 返回值 |
|---|---|---|
| `text(ctx, str)` | 自动换行文本块 | — |
| `label(ctx, str)` | 单行文本标签 | — |
| `button(ctx, label)` / `buttonEx(ctx, label, icon, opt)` | 按钮 | `res_submit` |
| `checkbox(ctx, label, state)` | 复选框，点击翻转 `*bool` | `res_change` |
| `textbox(ctx, buf)` / `textboxEx(ctx, buf, opt)` | 文本框（UTF-8，回车提交） | `res_submit` / `res_change` |
| `slider(ctx, value, low, high)` / `sliderEx(ctx, value, low, high, step, fmt, opt)` | 滑块（Shift+点击直接输入） | `res_change` |
| `number(ctx, value, step)` / `numberEx(ctx, value, step, fmt, opt)` | 数字拖拽控件 | `res_change` |
| `header(ctx, label)` / `headerEx(ctx, label, opt)` | 可折叠标题 | `res_active` |
| `beginTreeNode(ctx, label)` / `beginTreeNodeEx(ctx, label, opt)` / `endTreeNode(ctx)` | 树节点 | `res_active` |

#### 窗口 / 面板

| 方法 | 说明 |
|---|---|
| `beginWindow(ctx, title, rect)` / `beginWindowEx(ctx, title, rect, opt)` | 窗口开始（标题/关闭/拖动/缩放） |
| `endWindow(ctx)` | 窗口结束 |
| `openPopup(ctx, name)` | 打开弹出窗口（定位到鼠标处） |
| `beginPopup(ctx, name)` / `endPopup(ctx)` | 弹出窗口（点击外部自动关闭） |
| `beginPanel(ctx, name)` / `beginPanelEx(ctx, name, opt)` / `endPanel(ctx)` | 内嵌面板 |

### 回调（Context 字段，宿主实现）

| 字段 | 签名 | 说明 |
|---|---|---|
| `text_width` | `fn(ctx, str: []const u8) i32` | **必须实现**：测量文本像素宽度 |
| `text_height` | `fn(ctx) i32` | **必须实现**：字体行高 |
| `draw_frame` | `fn(ctx, rect, colorid) void` | 可选：控件底色绘制（默认画填充+边框） |

## 许可证

[MIT](LICENSE)。本项目为 [rxi/microui](https://github.com/rxi/microui)（MIT）的 Zig 重写版。
