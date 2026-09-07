# VideoTiming native regression test

This standalone native regression test includes the production `app/src/main/cpp/decoder/VideoTiming.h` directly; it does not use a timing-model duplicate or product code changes.

From the repository root, with the DevEco SDK available (set `DEVECO_SDK_ROOT` to the SDK root):

```powershell
$cmake = Join-Path $env:DEVECO_SDK_ROOT 'default\openharmony\native\build-tools\cmake\bin\cmake.exe'
$toolchain = Join-Path $env:DEVECO_SDK_ROOT 'default\openharmony\native\build\cmake\ohos.toolchain.cmake'
$build = 'Temp/scrcpyHmos-host-perf-20260907/cmake-build'
& $cmake -S app/src/test/native -B $build -G Ninja `
  ("-DCMAKE_TOOLCHAIN_FILE=$toolchain") `
  '-DOHOS_ARCH=arm64-v8a' '-DOHOS_PLATFORM=OHOS' '-DOHOS_STL=c++_static'
& $cmake --build $build
```

If the SDK installation exposes CMake elsewhere, use its bundled `cmake` and
Ninja paths; do not hard-code a machine-specific installation directory. The
successful local run used the SDK-bundled `native/build-tools/cmake/bin/cmake.exe`
and matching `ninja.exe`.

The resulting `VideoTimingTest` is an aarch64 OHOS ELF and must run on a compatible device; it must not be treated as a Windows executable. The expected runtime marker is `VIDEO_TIMING_REGRESSION_PASS`. No signing material or product build is required for this test target.
