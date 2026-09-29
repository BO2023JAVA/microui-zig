# 构建 Android arm64-v8a 所需的三个 .so 并拷贝到 app/libs/arm64-v8a/
#
# 用法:  powershell -ExecutionPolicy Bypass -File prepare_libs.ps1
#        （首次或更换 SDL 路径时，可用 -SdlSrc / -TtfSrc / -Ndk / -Cmake / -Ninja 覆盖参数）
#
# 前置条件:
#   - Zig 0.16（PATH 中可用 `zig`）
#   - Android SDK + NDK（默认 D:\dev\android，见下方参数）
#   - SDL3 与 SDL3_ttf 源码已下载，且 SDL3_ttf/external/freetype 已放好 freetype 源码
#     （SDL_ttf 源码包的 external/ 里只有下载脚本，需自行放入 freetype，参考 README 安卓一节）
#
# 之后打包 APK：cd android && gradlew.bat assembleDebug

param(
    [string]$SdlSrc = "D:\dev\android\sdl-src\SDL3-3.4.10",
    [string]$TtfSrc  = "D:\dev\android\sdl-src\SDL3_ttf-3.2.2",
    [string]$Cmake   = "D:\dev\android\sdk\cmake\3.22.1\bin\cmake.exe",
    [string]$Ninja   = "D:\dev\android\sdk\cmake\3.22.1\bin\ninja.exe",
    [string]$Ndk     = "D:\dev\android\sdk\ndk\28.2.13676358"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$dst  = Join-Path $PSScriptRoot "app\libs\arm64-v8a"
New-Item -ItemType Directory -Path $dst -Force | Out-Null

# 1) 交叉编译 SDL3
& $Cmake -S $SdlSrc -B (Join-Path $SdlSrc "build-android") -G Ninja -DCMAKE_MAKE_PROGRAM=$Ninja `
    "-DCMAKE_TOOLCHAIN_FILE=$Ndk\build\cmake\android.toolchain.cmake" `
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-34 -DCMAKE_BUILD_TYPE=Release `
    -DSDL_SHARED=ON -DSDL_STATIC=OFF
if ($LASTEXITCODE -ne 0) { throw "SDL3 cmake 配置失败" }
& $Cmake --build (Join-Path $SdlSrc "build-android")
if ($LASTEXITCODE -ne 0) { throw "SDL3 编译失败" }

# 2) 交叉编译 SDL_ttf（freetype 走 vendored）
& $Cmake -S $TtfSrc -B (Join-Path $TtfSrc "build-android") -G Ninja -DCMAKE_MAKE_PROGRAM=$Ninja `
    "-DCMAKE_TOOLCHAIN_FILE=$Ndk\build\cmake\android.toolchain.cmake" `
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-34 -DCMAKE_BUILD_TYPE=Release `
    "-DSDL3_DIR=$(Join-Path $SdlSrc 'build-android')" `
    -DSDLTTF_VENDORED=ON -DSDLTTF_HARFBUZZ=OFF -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF
if ($LASTEXITCODE -ne 0) { throw "SDL_ttf cmake 配置失败" }
& $Cmake --build (Join-Path $TtfSrc "build-android")
if ($LASTEXITCODE -ne 0) { throw "SDL_ttf 编译失败" }

# 3) 构建应用动态库（内嵌中文字体）
Push-Location $root
zig build android -Doptimize=ReleaseSmall
if ($LASTEXITCODE -ne 0) { throw "zig build android 失败" }
Pop-Location

# 4) 拷贝三个 .so
Copy-Item (Join-Path $SdlSrc "build-android\libSDL3.so")     $dst -Force
Copy-Item (Join-Path $TtfSrc "build-android\libSDL3_ttf.so") $dst -Force
Copy-Item (Join-Path $root "zig-out\lib\libmicrozig.so")    $dst -Force
Write-Output "三个 .so 已就位: $dst"
