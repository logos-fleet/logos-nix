# logos-nix

Shared Nix infrastructure for all Logos projects. Provides a single pinned `nixpkgs` and common build dependencies so downstream repos stay in sync without depending on an actual project as their flake root.

Previously, [`logos-cpp-sdk`](https://github.com/logos-co/logos-cpp-sdk) served as the `follows` root. This caused unnecessary cache invalidation on every SDK commit and coupled infrastructure concerns to an active development project.

## What it provides

| Output | Description |
|---|---|
| `nixpkgs` input | Pinned `nixos-unstable` revision shared across all projects |
| `devShells.default` | Common dev environment: `cmake`, `ninja`, `pkg-config`, `qt6.qtbase`, `qt6.qtremoteobjects` |
| `lib.forAllSystems` | Helper to generate outputs for all supported systems |
| `lib.supportedSystems` | `aarch64-darwin`, `x86_64-darwin`, `aarch64-linux`, `x86_64-linux` |
| `packages.aarch64-android.*` | Android (arm64-v8a) cross target: Qt 6.11.1, `androidPkgs`, and `mkQtAndroidApk`. See [Android target](#android-target-aarch64-android). |
| `lib.nativeOverlays` | Every overlay that belongs on a Linux/macOS package set, in order, as a list. This is what a consumer doing its own `import nixpkgs { overlays = ...; }` should apply — naming individual `lib.overlays.*` entries means a future overlay silently does not reach it. Never includes the Windows overlays, which must not touch a native set. |
| `lib.overlays.fetchCargoVendorUserAgent` | Makes `rustPlatform.fetchCargoVendor` send a User-Agent on the current pin (crates.io 403s python-requests' default). Applied by `forAllSystems`/`forAllTargets`/`legacyPackages`; a consumer that does its own `import nixpkgs` should apply `lib.nativeOverlays` rather than naming this one. See `nix/overlays/fetch-cargo-vendor-user-agent.nix`. |
| `lib.overlays.importCargoLockStaticCratesIo` | Points `rustPlatform.importCargoLock` at `static.crates.io` on the current pin (crates.io's `/api/v1/crates` 403s the `curl/...` User-Agent `fetchurl` sends). This is the fetcher a `cargoLock` build uses; `cargoHash` builds use `fetchCargoVendor` above, so a repo that builds Rust needs whichever matches its packages, or both. Applied by `forAllSystems`/`forAllTargets`/`legacyPackages`; a consumer that does its own `import nixpkgs` should apply `lib.nativeOverlays` rather than naming this one. See `nix/overlays/import-cargo-lock-static-crates-io.nix`. |
| `lib.overlays.fetchCrateStaticCratesIo` | Points `fetchCrate` at `static.crates.io` on the current pin — the third fetcher, and the one that pulls a crate's own *source* tarball rather than a vendored dependency. Reached from a module closure via qtdeclarative → qtsvg → jasper → libheif (`rav1e`, `cargo-c`). Swaps `fetchCrate`'s own `registryDl` default, so a caller naming a registry still wins. See `nix/overlays/fetch-crate-static-crates-io.nix`. |
| `packages.<system>.qt-wasm` | **Qt 6.11.1 for WebAssembly**, single-threaded and static, built from source: the QML runtime the Web container serves. With `qt-wasm-qml-probe`, which links a Qt Quick image against it and weighs it. See [Qt for WebAssembly](#qt-for-webassembly-packagessystemqt-wasm). |
| `lib.overlays.emscripten` | The **Emscripten pin** — `pkgs.logosEmscripten`, `pkgs.logosEmscriptenVersion`, `pkgs.logosEmscriptenSetup` (a shell snippet that puts `emcc` on `PATH` with a *writable* cache seeded from the store copy) and `pkgs.logosWasmCmakeToolchain` / `pkgs.logosWasmCmakeFlags`. One emsdk for every Logos wasm32 artifact, because a wasm host links C++ and Rust images that must share an ABI. Attribute-only, so it changes no other derivation's hash. Applied by `lib.nativeOverlays`. See [Wasm target](#wasm-target-wasm32-emscripten) and `nix/wasm/overlay.nix`. |

## Usage

### As a follows root (most projects)

```nix
{
  inputs = {
    logos-nix.url = "github:logos-co/logos-nix";
    nixpkgs.follows = "logos-nix/nixpkgs";
  };
}
```

### Using the dev shell

```nix
{
  inputs = {
    logos-nix.url = "github:logos-co/logos-nix";
    nixpkgs.follows = "logos-nix/nixpkgs";
  };

  outputs = { self, nixpkgs, logos-nix }:
    logos-nix.lib.forAllSystems ({ system, pkgs }: {
      devShells.default = pkgs.mkShell {
        inputsFrom = [ logos-nix.devShells.${system}.default ];
        # add project-specific deps here
      };
    });
}
```

## Migration from logos-cpp-sdk

```diff
 inputs = {
-  logos-cpp-sdk.url = "github:logos-co/logos-cpp-sdk";
-  nixpkgs.follows = "logos-cpp-sdk/nixpkgs";
+  logos-nix.url = "github:logos-co/logos-nix";
+  nixpkgs.follows = "logos-nix/nixpkgs";
+  logos-cpp-sdk.url = "github:logos-co/logos-cpp-sdk";  # only if you need the SDK
 };
```

Then run `nix flake update` to re-lock.


## iOS targets (`aarch64-ios-simulator`, `aarch64-ios`)

Qt 6.11.1 built from source as static frameworks for the iOS simulator and for
iOS devices, on the same cross pin as Windows. Only aarch64-darwin with Xcode installed can build it.

```bash
nix build .#packages.aarch64-ios-simulator.qtbase        # also qtdeclarative, qtshadertools, qtsvg, qtremoteobjects
nix build .#packages.aarch64-ios-simulator.boost         # liblogos_core's non-Qt tail: spdlog, boost, openssl, libsodium
nix build .#packages.aarch64-ios.qtbase                  # device (iphoneos SDK)
nix build .#legacyPackages.aarch64-darwin.pkgsIosSimulator.qt6.qtbase   # the full cross sets: pkgsIosSimulator, pkgsIos
```

The pseudo-system is opt-in: `lib.forAllMobileTargets` iterates `lib.mobileTargets`
(`aarch64-ios-simulator`, `aarch64-ios`; Android keys join the same list), while
`lib.forAllTargets` stays native + Windows. A consumer gets `pkgs.logosQtCrossCmakeFlags`
(appendable `-D` flags, `[]` natively) and `pkgs.logosQtCrossToolchainFile`
(`qt.toolchain.cmake` of the iOS qtbase, to pass as `CMAKE_TOOLCHAIN_FILE`).

An app's own static-archive stage is `pkgs.mkIosCmakeStage { pname; version; src;
sourceDir ? "."; cmakeFlags ? []; buildInputs ? []; exportedSymbols ? [];
exportedSymbolFiles ? []; }`: the same Xcode-clang setup
the Qt modules use (`nix/ios/xcode-clang.nix`), the toolchain file and cross flags
applied, Qt on the path, and a post-install gate that fails on any dynamic image.

**Symbols for dlopened modules.** The iOS Qt is built with
`-DFEATURE_reduce_exports=OFF` (`nix/ios/qt-module.nix`, qtbase; the other
modules inherit it through `Qt6::Core`'s `QT_ENABLED_*_FEATURES`). With it on, a
static Qt's whole API is `private external` in the archives and becomes local
when an app links them, so an app image exports no Qt and a module dlopened into
it cannot resolve a single symbol upward — the precondition ADR 0006 needs. The
flag costs an app nothing on its own: which symbols an executable actually
exports is decided at its link.

That link is `logos_ios_export_symbols()`, in the CMake module at
`pkgs.logosIosSymbolExports`:

```cmake
include(${LOGOS_IOS_CMAKE_DIR}/LogosIosSymbolExports.cmake)
logos_ios_export_symbols(MyApp
    SYMBOLS      _lp_protocol_version
    SYMBOL_FILES ${LOGOS_IOS_EXPORTED_SYMBOLS_FILE})
```

It adds `-u <sym>` for each name (the archive member is otherwise never pulled
in, since nothing in the app references what only a module calls) and an
`-exported_symbols_list` of exactly that set. The list is the default and
`EXPORT_ALL` is a noisy opt-out.

**Call it, or pay for it.** With reduce_exports off, an iOS app that passes no
list exports every default-visibility global it linked, and exports are
dead-strip roots. Measured on the shell-preview, simulator, same Qt:

| build | executable | exports | export trie |
|---|---|---|---|
| no list (what an app gets by default) | 51 656 824 B | 67 188 | 3 171 552 B |
| dlopen spike, `EXPORT_ALL` | 51 733 272 B | 67 288 | 3 176 008 B |
| dlopen spike, list of 27 | 45 831 256 B | 27 | 1 000 B |

So the spike's own code is +76 KB and the list is worth 5.8 MB. Every iOS app
image in this stack should call `logos_ios_export_symbols()`.

`mkIosCmakeStage` passes `-DLOGOS_IOS_CMAKE_DIR` always, and
`-DLOGOS_IOS_EXPORTED_SYMBOLS_FILE` when `exportedSymbols`/`exportedSymbolFiles`
are non-empty (sorted and deduplicated into one store file). Both are repeated in
`stage.passthru.logosIosSymbolExports.{cmakeDir,symbolsFile,cmakeFlags}`, because
on iOS the app target is linked by Xcode outside nix and that impure half has to
pass the same flags. The usual source of `exportedSymbolFiles` is the module set
itself — each Bare module's `nm -u`, intersected with what the app defines. See
`docs/research/spikes/ios-dlopen-bare-module.md` in logos-workspace.

**One more thing Qt hides.** `reduce_exports` alone is not enough:
`qmetatype.h` wraps the `QMetaTypeInterfaceWrapper<T>::metaType` definitions in
an unconditional `#pragma GCC visibility push(hidden)` on non-Windows clang,
while the same header declares them `extern template` for every builtin type --
so a module never instantiates its own and references qtbase's, which the pragma
made unexportable. Any module with a `QString` property hits it. The iOS qtbase
therefore also rewrites that pragma to `push(default)` (`--replace-fail`, so a
Qt bump that moves it fails the build). The alternative -- every module
compiled with Qt's private `QT_NO_DATA_RELOCATION` so it instantiates its own
hidden copy -- was measured to work as well, but puts a Qt-internal define in
every module recipe and gives each module its own `QMetaTypeInterface` objects.

Checks: `ios-overlay` (eval-only drift gate), `ios-symbol-exports` (links the same
program with and without the helper and asserts the difference; no Qt, seconds),
`ios-qt-exports-simulator` / `ios-qt-exports-device` (read the rebuilt Qt's Mach-O
symbol tables, including a qtdeclarative symbol, so the inheritance is asserted
and not assumed).

**Purity boundary.** Everything iOS compiles with Xcode's clang and the
iPhoneSimulator or iPhoneOS SDK from `/Applications/Xcode.app`, which cannot live in the
store, so those derivations are `__noChroot`. They still produce
ordinary cacheable store paths, but nothing iOS is bit-for-bit reproducible.
The default macOS `sandbox = false` needs nothing; a machine with a strict
sandbox must set `sandbox = relaxed`. An app's own Xcode-generator configure,
`xcodebuild` and `xcrun simctl` steps against the store Qt stay outside nix.

**Xcode gate.** `nix/ios/xcode-wrapper.nix` is named after the declared Xcode
version and build (`iosXcodeVersion`/`iosXcodeBuild` in `flake.nix`), so they
are in every dependent hash, and its setup hook fails any build early when the
installed Xcode differs, naming both. Bumping Xcode means bumping those two
strings and rebuilding Qt.

**Prebuilt fallback.** If from-source ever breaks on a new Qt or Xcode, the
documented fallback is Qt's official iOS archives as fixed-output fetches behind
the same `packages.aarch64-ios*.*` names, moving all Xcode
impurity into the app's link step. Not implemented: from-source works.

## Android target (`aarch64-android`)

Qt 6.11.1 cross-built from nixpkgs' `qt6` recipe for `arm64-v8a`, on the same
cross pin as Windows, plus a composed `androidenv` SDK/NDK and
`mkQtAndroidApk`, which packages a Qt CMake project as a debug-signed APK
entirely inside a derivation. Builds from x86_64-linux under a strict sandbox
and from aarch64-darwin.

```bash
nix build .#packages.aarch64-android.qtbase          # also qtdeclarative, qtshadertools, qtsvg, qtremoteobjects
nix build .#packages.aarch64-android.boost           # liblogos_core's non-Qt tail: spdlog, boost, openssl, libsodium
nix build .#legacyPackages.x86_64-linux.pkgsAndroid.qt6.qtbase   # the full cross set
nix build .#checks.x86_64-linux.android-apk          # smallest mkQtAndroidApk consumer
```

`packages.aarch64-android.*` is pinned to the x86_64-linux build platform: a
flake output path cannot depend on the machine evaluating it under pure eval.
From aarch64-darwin use `legacyPackages.aarch64-darwin.pkgsAndroid.*`, the
same expression with `localSystem` swapped; the APK check is x86_64-linux only,
and its consumer builds from a Mac with:

```bash
nix build --impure --expr \
  '(builtins.getFlake (toString ./.)).legacyPackages.aarch64-darwin.pkgsAndroid.callPackage ./nix/android/check-apk {}'
```

The pseudo-system is opt-in: `lib.forAllMobileTargets` iterates `lib.mobileTargets`
(`aarch64-android`; iOS keys join the same list), while `lib.forAllTargets` stays
native + Windows. A consumer that has to realise Android derivations on a Mac
builds its own list with `lib.mkMobileTargets { androidBuildSystem = "aarch64-darwin"; }`
and iterates it with `lib.mkForAllMobileTargets`; the derivations are the same
closure, keyed by the build platform that can run them. A consumer gets `pkgs.logosQtCrossCmakeFlags`
(appendable `-D` flags, `[]` natively) and `pkgs.logosQtCrossToolchainFile` (the
NDK's `android.toolchain.cmake`, to pass as `CMAKE_TOOLCHAIN_FILE`), plus
`pkgs.androidPkgs` (the composed SDK/NDK), `pkgs.logosQtHost` (the
build-platform Qt at the same version, for `androiddeployqt`) and
`pkgs.mkQtAndroidApk`.

### Packaging an APK

```nix
pkgs.mkQtAndroidApk {
  pname = "my-app";
  version = "1.0";
  src = ./.;                       # a CMake project using qt_add_executable
  target = "my_app";               # the qt_add_executable target
  packageName = "io.logos.myapp";  # equals the target's QT_ANDROID_PACKAGE_NAME
  # abi ? androidPkgs.abi; qtModules ? [ qtbase qtdeclarative qtsvg ]
}
```

`$out/<pname>-<version>.apk` is signed with the committed debug key
(`nix/android/debug.keystore`) and installs with `adb install -r -g`. Every
shipped `.so` is read with `llvm-readelf` and the build fails if any `DT_NEEDED`
is neither packaged nor in the NDK's stub libraries for the target API level.
That gate sees link-time `DT_NEEDED` only, never a `dlopen`, which is exactly
where the OpenSSL gap below lives. See `nix/android/check-apk/` for the
smallest complete consumer.

### Adding an ABI

One ABI is one pseudo-system: the NDK triple, the nixpkgs `crossSystem` and
every Qt library are per-ABI. To add `armeabi-v7a`, add an `armv7a-android` key
to `lib.mobileTargets` with `config = "armv7a-unknown-linux-androideabi"` and
`abi = "armeabi-v7a"`; `ndkTriple` in the overlay already maps the four ABIs. A
multi-ABI APK then merges the per-ABI `libs/` trees before gradle runs — slice
09, not this one.

### Gotchas

Qt refuses to configure for Android without the NDK's own
`android.toolchain.cmake`, which `set()`s `CMAKE_C_COMPILER` to the NDK clang and
so bypasses the nixpkgs cc-wrapper for qtbase itself. Target *dependencies* still
go through the wrapper; both resolve to the same NDK clang, so the ABI matches.

Building *from* aarch64-darwin needs `xcbuild` in `nativeBuildInputs`, even
though nothing Apple is targeted: Qt's `qt_auto_detect_apple()` guards only on
CMake's host-derived `APPLE` and calls `xcrun` before the Android toolchain file
is read. Expect `patchelf: command not found` warnings from nixpkgs' NDK
toolchain derivation on that platform — nixpkgs runs the ELF fixup for the
Android host without putting patchelf on a darwin build platform's PATH. It is
noise; fixing it would change the toolchain hash and rebuild all of Qt.

Qt is built against its own `src/3rdparty` copies of zlib, PCRE2, libb2,
double-conversion, libpng, libjpeg, md4c, FreeType, HarfBuzz and SQLite, not
nixpkgs'. This is not a preference: a nixpkgs system library becomes a
`DT_NEEDED` soname that `androiddeployqt` does not bundle and Android does not
provide, and the app dies at its first `dlopen` with `UnsatisfiedLinkError`
(measured on a physical arm64 device). `mkQtAndroidApk`'s `DT_NEEDED` gate is
what turns that into a build failure.

**Known limitation.** Qt is configured with `openssl_runtime`, not
`openssl_linked`, which is how Qt's own Android builds ship: `libQt6Network`
`dlopen`s libssl at run time. Nothing bundles it yet, so an app that needs TLS
must add a per-ABI `libssl`/`libcrypto` via `QT_ANDROID_EXTRA_LIBS`.

### Regenerating the gradle lock

`nix/android/deps.json` is the `gradle.fetchDeps` lockfile, and the only part
of an APK build that ever touches the network. It locks Qt's gradle template,
not any app, so one file serves every `mkQtAndroidApk` consumer. The build
itself runs in the ordinary sandbox with no network at all: nixpkgs' `mitmCache`
hook starts a local `mitm-cache` proxy that replays this file, and gradle is
pointed at it. Regenerate (never hand-edit) from the repo root with:

```
$(nix build --no-link --print-out-paths \
    .#checks.x86_64-linux.android-apk.mitmCache.updateScript)
```

The update task is `assembleDebug`, not nixpkgs' default `nixDownloadDeps`, so
the lock holds exactly what a real build resolves. aapt2 is pinned to the SDK's
own binary rather than Maven's, which keeps per-build-platform artifacts out of
the lock — the same `deps.json` works from x86_64-linux and aarch64-darwin.

Measured on x86_64-linux (WSL, 32 cores, `--cores 16 --max-jobs 2`, target
dependencies and the SDK already in the store): the four Qt modules build in
**5m28s**; their combined closure is **4.6 GiB**, of which **4.2 GiB** is the
androidenv SDK + NDK. An APK derivation takes about a minute on top; a
one-window app is 19 MiB.

## Wasm target (`wasm32-emscripten`)

There is no `packages.wasm32-emscripten.*` pseudo-system here, and that is
deliberate: unlike iOS and Android, a wasm artifact is not produced by a nixpkgs
*cross package set*. Emscripten brings its own sysroot, its own libc and its own
libc++, and nixpkgs' `pkgsCross.wasi32` is a different (WASI, not Emscripten)
target that cannot link the JS glue a browser host needs. So what this repo pins
is the **toolchain**, and each consumer drives `emcc` itself from an ordinary
native derivation.

```nix
pkgs.stdenv.mkDerivation {
  # ...
  preConfigure = pkgs.logosEmscriptenSetup;   # emcc on PATH, writable EM_CACHE
  cmakeFlags = pkgs.logosWasmCmakeFlags;      # -DCMAKE_TOOLCHAIN_FILE=...
}
```

`pkgs.logosEmscriptenSetup` copies the 84 MB store cache into `$TMPDIR` and makes
it writable. Skipping it is the failure everybody hits once: a `-O2` link wants a
build of libc++ that the store copy does not ship (nixpkgs ships the `-debug`
variants), emcc goes to build it, and the store is read-only.

`pkgs.logosEmscriptenVersion` is the pin as data, for a backend that installs its
own toolchain — a Rust core reaching wasm through `wasm32-unknown-emscripten` has
to use *this* emsdk or its libc++ will not match the C++ half of the same image.

`checks.<system>.emscripten-pin` compiles a C++ translation unit and reads the
`\0asm` magic off the object, so the pin is proven by use rather than by an
attribute existing.

`pkgs.logosEmsdk` is the same emscripten in the **layout an emsdk checkout has**
(`upstream/emscripten` plus a `.emscripten` whose `EMSCRIPTEN_ROOT` is relative),
and `logosEmscriptenSetup` exports `EMSDK` pointing at it. Only Qt needs this:
`qt_auto_detect_wasm()` is a `FATAL_ERROR` when `EMSDK` is unset and then reads
the root suffix out of `$EMSDK/.emscripten`, where nixpkgs' own copy has an
absolute store path. emcc itself never looks at `EMSDK`.

### Qt for WebAssembly (`packages.<system>.qt-wasm`)

The QML runtime the Web container serves (ADR 0004 in logos-workspace) is Qt
**6.11.1 for wasm32-emscripten, single-threaded, static**, built from source
here:

| Output | What it is |
|---|---|
| `packages.<system>.qt-wasm` | One prefix with all five modules, for `CMAKE_PREFIX_PATH` / `CMAKE_FIND_ROOT_PATH` |
| `packages.<system>.qt-wasm-qtbase` … `-qtdeclarative`, `-qtshadertools`, `-qtsvg`, `-qtremoteobjects` | The modules on their own |
| `packages.<system>.qt-wasm-qml-probe` | A Qt Quick + Controls + Svg + QtRO image, linked and **weighed** (raw and brotli, against ADR 0004's budget) |
| `checks.x86_64-linux.qt-wasm-qml-probe` | The same probe, in `nix flake check` — Linux-only, like `android-apk`, because it builds Qt from source |
| `lib.qtWasmFor <system>` | The module set plus `cmakeFlags`, for a consumer that wants the pieces |

```nix
# A wasm app against this Qt: one toolchain file, one prefix.
pkgs.stdenv.mkDerivation {
  buildPhase = ''
    ${pkgs.logosEmscriptenSetup}
    cmake -S . -B build -GNinja ${lib.escapeShellArgs qtWasm.cmakeFlags}
    cmake --build build
  '';
}
```

Two pins meet in this build and they are deliberately different ones: the
**emsdk** is the native pin's (above), because the runtime's image sits next to
logos-protocol's wasm transport and a module core compiled by the same emsdk;
the **Qt** is `nixpkgs-windows`' 6.11.1, the version iOS, Android and Windows
already use and the one ADR 0004's spike measured. Qt refuses a host path whose
version differs from the target's, so the host tools (moc, rcc, qmlcachegen,
qsb, repc) come from the same scope as the sources — see `nix/wasm/qt.nix`, and
`nix/ios/qt-module.nix` for the shape it is lifted from.

`QT_FEATURE_thread=OFF` is passed explicitly: threads in a webview need
`crossOriginIsolated`, which the spike could not obtain on Android WebView at
all, and ADR 0004's size and memory budget is the single-threaded one.
