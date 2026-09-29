const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SDL3 根目录（含 include / lib / bin），可用 -Dsdl=... 覆盖
    const sdl_dir = b.option([]const u8, "sdl", "SDL3 根目录（含 include/lib/bin）") orelse
        "C:\\Users\\one\\env\\SDL\\SDL3-3.4.10\\x86_64-w64-mingw32";

    // SDL3 各子目录（绝对路径用 cwd_relative 形式）
    const sdl_include = b.pathJoin(&.{ sdl_dir, "include" });
    const sdl_dll = b.pathJoin(&.{ sdl_dir, "bin", "SDL3.dll" });
    // MinGW 的 SDL3 导入库文件名是 libSDL3.dll.a，直接用对象文件方式链接
    const sdl_import_lib = b.pathJoin(&.{ sdl_dir, "lib", "libSDL3.dll.a" });

    // 核心库模块（前端）
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/microui.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 示例应用内容（平台无关的窗口与逻辑）
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "microui", .module = lib_mod } },
    });

    // SDL3 渲染后端模块（依赖核心库 + SDL + GDI）
    const renderer_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "microui", .module = lib_mod } },
    });
    renderer_mod.strip = optimize != .Debug;
    renderer_mod.addIncludePath(.{ .cwd_relative = sdl_include });
    renderer_mod.addObjectFile(.{ .cwd_relative = sdl_import_lib });
    renderer_mod.link_libc = true; // cImport 引入的 C 头文件需要 libc
    renderer_mod.linkSystemLibrary("gdi32", .{}); // 中文动态字集用到 GDI 字体栅格化

    // 演示程序
    const demo = b.addExecutable(.{
        .name = "microui-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "microui", .module = lib_mod },
                .{ .name = "renderer", .module = renderer_mod },
                .{ .name = "app", .module = app_mod },
            },
        }),
    });
    // 发布模式剥离调试信息，显著缩小体积
    demo.root_module.strip = optimize != .Debug;
    demo.root_module.addIncludePath(.{ .cwd_relative = sdl_include });
    demo.root_module.addObjectFile(.{ .cwd_relative = sdl_import_lib });
    demo.root_module.link_libc = true; // cImport 引入的 C 头文件需要 libc
    demo.root_module.linkSystemLibrary("gdi32", .{}); // 事件/输入映射用到 SDL，GDI 链接保持一致

    b.installArtifact(demo);

    // 把 SDL3.dll 一并装进 zig-out/bin，保证可直接运行
    const dll = b.addInstallFileWithDir(.{ .cwd_relative = sdl_dll }, .bin, "SDL3.dll");
    b.getInstallStep().dependOn(&dll.step);

    const run = b.addRunArtifact(demo);
    run.step.dependOn(&dll.step);
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "运行 microui 演示程序");
    run_step.dependOn(&run.step);

    // ===== Android arm64-v8a（libmicrozig.so，供 SDLActivity 加载） =====
    // 前置：先按 README 安卓一节交叉编译 libSDL3.so / libSDL3_ttf.so
    const sdl3_src = "D:\\dev\\android\\sdl-src\\SDL3-3.4.10";
    const ttf_src = "D:\\dev\\android\\sdl-src\\SDL3_ttf-3.2.2";
    // Zig 0.16 中 Android 表示为 linux 系统 + android ABI
    const android_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android });

    const lib_mod_android = b.createModule(.{
        .root_source_file = b.path("src/microui.zig"),
        .target = android_target,
        .optimize = optimize,
    });
    // SDL3/SDL_ttf 手写绑定（无 cImport，供 Android 端使用）
    const sdl3_android_mod = b.createModule(.{
        .root_source_file = b.path("src/sdl3_android.zig"),
        .target = android_target,
        .optimize = optimize,
    });
    const app_mod_android = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = android_target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "microui", .module = lib_mod_android } },
    });
    const renderer_android_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer_android.zig"),
        .target = android_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "microui", .module = lib_mod_android },
            .{ .name = "sdl3_android", .module = sdl3_android_mod },
        },
    });
    setupAndroidModule(renderer_android_mod, optimize, sdl3_src, ttf_src);

    const main_android_mod = b.createModule(.{
        .root_source_file = b.path("src/main_android.zig"),
        .target = android_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "microui", .module = lib_mod_android },
            .{ .name = "renderer", .module = renderer_android_mod },
            .{ .name = "app", .module = app_mod_android },
            .{ .name = "sdl3_android", .module = sdl3_android_mod },
        },
    });
    setupAndroidModule(main_android_mod, optimize, sdl3_src, ttf_src);

    // 共享库名 "microzig"：SDLActivity 的 getLibraries() 期望 libmicrozig.so
    const android_lib = b.addLibrary(.{
        .name = "microzig",
        .root_module = main_android_mod,
        .linkage = .dynamic,
        .version = null,
    });
    b.installArtifact(android_lib);

    const android_step = b.step("android", "构建 Android arm64-v8a 的 libmicrozig.so");
    android_step.dependOn(&android_lib.step);
    android_step.dependOn(b.getInstallStep()); // 一并安装产物（zig-out/lib/libmicrozig.so）
}

/// Android 模块公共配置：链接 SDL3 / SDL_ttf 的 .so。
/// 无 cImport 也无 libc：SDL/TTF 调用走手写绑定（sdl3_android.zig），
/// 符号由两个 .so 提供，Zig std 在 linux 上走内联系统调用。
fn setupAndroidModule(
    mod: *std.Build.Module,
    optimize: std.builtin.OptimizeMode,
    sdl3_src: []const u8,
    ttf_src: []const u8,
) void {
    mod.strip = optimize != .Debug;
    mod.addObjectFile(.{ .cwd_relative = std.fs.path.joinZ(
        std.heap.page_allocator,
        &.{ sdl3_src, "build-android", "libSDL3.so" },
    ) catch @panic("oom") });
    mod.addObjectFile(.{ .cwd_relative = std.fs.path.joinZ(
        std.heap.page_allocator,
        &.{ ttf_src, "build-android", "libSDL3_ttf.so" },
    ) catch @panic("oom") });
}
