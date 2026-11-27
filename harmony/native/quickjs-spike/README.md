# QuickJS NAPI spike

P1a build-only spike for the upstream v3 source runtime.

Goal: compile QuickJS-NG for HarmonyOS arm64 and expose one NAPI `eval(script)` function.

This is not wired into the app yet. It only proves the native build and module shape.

Build locally with the HarmonyOS command-line-tools:

```bash
export HARMONY_CLI_HOME=/path/to/command-line-tools
TOOLCHAIN=$(find "$HARMONY_CLI_HOME/sdk" -path '*/native/build/cmake/ohos.toolchain.cmake' | head -1)
cmake -S harmony/native/quickjs-spike -B build-quickjs-spike \
  -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DOHOS_ARCH=arm64-v8a \
  -DOHOS_PLATFORM=OHOS \
  -DQUICKJS_SRC=/path/to/quickjs-0.18.0 \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build-quickjs-spike
```

Expected output: `libquickjs_spike.so`.
