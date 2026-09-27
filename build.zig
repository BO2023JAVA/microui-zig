const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SDL3 根目录（含 include / lib / bin），可用 -Dsdl=... 覆盖
    const sdl_dir = b.option([]const u8, "sdl", "SDL3 根目录（含 include/lib/bin）") orelse
        "C:\\Users\\one\\env\\SDL\\SDL3-3.4.10\\x86_64-w64-mingw32";

    // 核心库模块
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/microui.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 演示程序
    const demo = b.addExecutable(.{
        .name = "microui-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "microui", .module = lib_mod } },
        }),
    });
    // 发布模式剥离调试信息，显著缩小体积
    demo.root_module.strip = optimize != .Debug;
    // SDL3 各子目录（绝对路径用 cwd_relative 形式）
    const sdl_include = b.pathJoin(&.{ sdl_dir, "include" });
    const sdl_dll = b.pathJoin(&.{ sdl_dir, "bin", "SDL3.dll" });
    // MinGW 的 SDL3 导入库文件名是 libSDL3.dll.a，直接用对象文件方式链接
    const sdl_import_lib = b.pathJoin(&.{ sdl_dir, "lib", "libSDL3.dll.a" });

    demo.root_module.addIncludePath(.{ .cwd_relative = sdl_include });
    demo.root_module.addObjectFile(.{ .cwd_relative = sdl_import_lib });
    demo.root_module.link_libc = true; // cImport 引入的 C 头文件需要 libc
    demo.root_module.linkSystemLibrary("gdi32", .{}); // 中文动态字集用到 GDI 字体栅格化

    b.installArtifact(demo);

    // 把 SDL3.dll 一并装进 zig-out/bin，保证可直接运行
    const dll = b.addInstallFileWithDir(.{ .cwd_relative = sdl_dll }, .bin, "SDL3.dll");
    b.getInstallStep().dependOn(&dll.step);

    const run = b.addRunArtifact(demo);
    run.step.dependOn(&dll.step);
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "运行 microui 演示程序");
    run_step.dependOn(&run.step);
}
