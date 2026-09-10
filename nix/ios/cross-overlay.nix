# iOS (arm64-apple-ios) cross overlay — HOST-side, applied via `crossOverlays`.
# Every compile goes through the version-gated Xcode wrapper in `__noChroot`
# derivations; nixpkgs' own iOS toolchain is not used.
final: prev:

let
  lib = final.lib;
  hostPlatform = final.stdenv.hostPlatform;
  isCross = !final.stdenv.buildPlatform.canExecute hostPlatform;

  hostQt = final.pkgsBuildBuild.qt6;

  # Read from `prev`, not `final`: this decides which attribute NAMES the
  # overlay contributes, and in a nixpkgs overlay the set of names may not
  # depend on `final` -- the fixpoint cannot be constructed at all. It also
  # has to be right: overriding openssl on a NATIVE darwin set trips an
  # assertion inside the stdenv bootstrap ("expected a set but found null",
  # from isBuiltByBootstrapFilesCompiler on a cc-less stdenvNoCC).
  contributesTail = !prev.stdenv.buildPlatform.canExecute prev.stdenv.hostPlatform;

  appleSdk = if hostPlatform.darwinPlatform == "ios-simulator" then "iphonesimulator" else "iphoneos";
  arch = hostPlatform.darwinArch;

  # The Qt modules Logos consumes; order matters for the prefix-path lists.
  qtModules = [
    "qtbase"
    "qtdeclarative"
    "qtshadertools"
    "qtsvg"
    "qtremoteobjects"
  ];

  # The iOS SDK floor every hand-rolled third-party build below targets. Qt's
  # own modules take theirs from macx-ios-clang; this number only has to be
  # <= that one, or the archives will not link into the app.
  iosDeploymentTarget = "17";

  prefixPath = scope: lib.concatStringsSep ";" (map (m: "${scope.${m}}") qtModules);

  # The clang target triple for this set's SDK. Single-sourced here because
  # three consumers need the SAME one: the hand-rolled third-party archives,
  # a plain (non-Qt) CMake project, and cargo's iOS target.
  triple = "${arch}-apple-ios${iosDeploymentTarget}"
    + lib.optionalString (appleSdk == "iphonesimulator") "-simulator";

  # cargo's spelling of the same platform, which is not clang's.
  rustTarget = "aarch64-apple-ios" + lib.optionalString (appleSdk == "iphonesimulator") "-sim";
in
{
  xcodeWrapper = final.pkgsBuildBuild.callPackage ./xcode-wrapper.nix {
    inherit (hostPlatform) xcodeBuild;
    xcodeVersion = hostPlatform.xcodeVer;
  };

  # Same contract as the Windows overlay: `pkgs.logosQtCrossCmakeFlags or []`
  # is appendable -D flags only, empty natively. The toolchain file (which
  # carries CMAKE_SYSTEM_NAME=iOS and the SDK/arch qtbase was built with) is
  # a separate attribute because a consumer may already pass its own.
  logosQtCrossToolchainFile =
    lib.optionalString isCross "${final.qt6.qtbase}/lib/cmake/Qt6/qt.toolchain.cmake";

  logosQtCrossCmakeFlags = lib.optionals isCross [
    "-DCMAKE_OSX_SYSROOT=${appleSdk}"
    "-DCMAKE_OSX_ARCHITECTURES=${arch}"
    "-DQT_HOST_PATH=${hostQt.qtbase}"
    "-DQT_ADDITIONAL_HOST_PACKAGES_PREFIX_PATH=${prefixPath hostQt}"
    "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH=${prefixPath final.qt6}"
  ];

  # ── the platform, named ────────────────────────────────────────────────
  # What a NON-Qt project targeting this set needs. A Qt project gets the same
  # from qt.toolchain.cmake, so these are for everything else -- a Bare module
  # among them, which by definition links no Qt at all.
  logosIosAppleSdk = appleSdk;
  logosIosArch = arch;
  logosIosDeploymentTarget = iosDeploymentTarget;
  logosIosTriple = triple;
  logosIosCmakeTargetFlags = lib.optionals isCross [
    "-DCMAKE_SYSTEM_NAME=iOS"
    "-DCMAKE_OSX_SYSROOT=${appleSdk}"
    "-DCMAKE_OSX_ARCHITECTURES=${arch}"
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=${iosDeploymentTarget}"
    # CMAKE_SYSTEM_NAME=iOS makes CMake cross-compiling, and cross-compiling
    # re-roots find_package/find_path/find_library into CMAKE_FIND_ROOT_PATH --
    # even a `PATHS ... NO_DEFAULT_PATH` one. Store paths are not under the
    # SDK, so a header-only dependency (nlohmann_json, an installed CMake
    # config package) goes from present to invisible. The Android toolchain
    # file sets the same three for the same reason.
    "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH"
    "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH"
    "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH"
  ];

  # ── cross-compiling a Rust crate for this set ──────────────────────────
  # A SHELL SNIPPET, not an attrset of store paths, because the iOS toolchain
  # is Xcode's and is only knowable at build time through `xcrun` (ADR 0002).
  # Android's half of this contract is the same two attribute names, so a
  # consumer writes one code path for both. Needs xcodeWrapper on PATH.
  logosRustCrossTarget = lib.optionalString isCross rustTarget;
  logosRustCrossSetup = lib.optionalString isCross ''
    # DEVELOPER_DIR first, and it is load-bearing. A cargo cross build runs in
    # the BUILD platform's stdenv so that the toolchain is runnable, and the
    # Darwin cc-wrapper in that stdenv points DEVELOPER_DIR at nixpkgs' macOS
    # SDK -- which contains no iPhone SDK, so `xcrun --sdk ${appleSdk}` answers
    # "unable to find sdk" on STDOUT and exits 0. `set -e` never fires and the
    # variable is set to an error message.
    export DEVELOPER_DIR="${final.xcodeWrapper.developerDir}"
    _sdkroot="$(xcrun --sdk ${appleSdk} --show-sdk-path)"
    [ -d "$_sdkroot" ] || { echo "logos-nix: xcrun could not resolve the ${appleSdk} SDK: $_sdkroot" >&2; exit 1; }
    # SDKROOT is deliberately NOT exported. The same cargo run compiles this
    # crate's build scripts and proc macros for the BUILD platform, and a
    # process-wide SDKROOT pointing at the iPhone SDK makes those link against
    # it -- measured: `quote`'s build script died on "symbol(s) not found for
    # architecture arm64" while building for macOS. Everything below is keyed
    # to the TARGET triple instead, so the host half is untouched.
    export CARGO_BUILD_TARGET=${rustTarget}
    _clang="$(xcrun --sdk ${appleSdk} --find clang)"
    _clangxx="$(xcrun --sdk ${appleSdk} --find clang++)"
    # cargo keys the linker off the triple with dashes turned into underscores
    # and upper-cased; cc-rs keys CC_/CXX_/AR_/CFLAGS_ off the same triple
    # lower-cased. Without the cc-rs half a build script compiles its bundled C
    # for the BUILDER and the link fails on undefined symbols -- silently,
    # because the archive is still produced.
    export CARGO_TARGET_${builtins.replaceStrings [ "-" ] [ "_" ] (lib.toUpper rustTarget)}_LINKER="$_clang"
    # rustc would normally read the SDK out of SDKROOT; it is not exported (see
    # above), so the target link is told where it is directly.
    export CARGO_TARGET_${builtins.replaceStrings [ "-" ] [ "_" ] (lib.toUpper rustTarget)}_RUSTFLAGS="-Clink-arg=-isysroot -Clink-arg=$_sdkroot -Clink-arg=-target -Clink-arg=${triple}"
    export CC_${builtins.replaceStrings [ "-" ] [ "_" ] rustTarget}="$_clang"
    export CXX_${builtins.replaceStrings [ "-" ] [ "_" ] rustTarget}="$_clangxx"
    export AR_${builtins.replaceStrings [ "-" ] [ "_" ] rustTarget}="$(xcrun --sdk ${appleSdk} --find ar)"
    export CFLAGS_${builtins.replaceStrings [ "-" ] [ "_" ] rustTarget}="-target ${triple} -isysroot $_sdkroot"
    export CXXFLAGS_${builtins.replaceStrings [ "-" ] [ "_" ] rustTarget}="-target ${triple} -isysroot $_sdkroot"
  '';

  # ── cross-compiling a Nim project for this set ─────────────────────────
  # Nim knows `ios` as an OS; what it does not know is where Xcode is, so the
  # compiler and the SDK are passed in. Same two attribute names on Android.
  logosNimCrossFlags = lib.optionals isCross [
    "--os:ios"
    "--cpu:arm64"
    "--cc:clang"
  ];
  logosNimCrossSetup = lib.optionalString isCross ''
    export DEVELOPER_DIR="${final.xcodeWrapper.developerDir}"
    export SDKROOT="$(xcrun --sdk ${appleSdk} --show-sdk-path)"
    [ -d "$SDKROOT" ] || { echo "logos-nix: xcrun could not resolve the ${appleSdk} SDK: $SDKROOT" >&2; exit 1; }
    nimFlagsArray+=(
      "--clang.exe=$(xcrun --sdk ${appleSdk} --find clang)"
      "--clang.cpp.exe=$(xcrun --sdk ${appleSdk} --find clang++)"
      "--clang.linkerexe=$(xcrun --sdk ${appleSdk} --find clang)"
      "--clang.cpp.linkerexe=$(xcrun --sdk ${appleSdk} --find clang++)"
      "--passC:-target ${triple}"
      "--passC:-isysroot $SDKROOT"
      "--passL:-target ${triple}"
      "--passL:-isysroot $SDKROOT"
    )
  '';

  # How everything iOS compiles; qt-module.nix and mkIosCmakeStage share it.
  xcodeClang = final.callPackage ./xcode-clang.nix {
    inherit (final) xcodeWrapper;
    inherit appleSdk;
    inherit (final.pkgsBuildBuild) cmake ninja;
  };

  # `logos_ios_export_symbols()`: the app-side half of ADR 0006, where the
  # symbols a dlopened Bare module resolves upward are forced into the app
  # image and exported from it. Its own store path rather than a file in the
  # stage, because the target that needs it is the app executable, and on iOS
  # that is linked by Xcode outside nix -- so the impure half has to be able to
  # `include()` the same module the pure half saw. mkIosCmakeStage passes the
  # dir as -DLOGOS_IOS_CMAKE_DIR and repeats it in passthru for that hand-off.
  logosIosSymbolExports = final.pkgsBuildBuild.runCommandLocal "logos-ios-symbol-exports-cmake" { } ''
    mkdir -p $out
    cp ${./LogosIosSymbolExports.cmake} $out/LogosIosSymbolExports.cmake
  '';

  # An app's static-archive stage: `pkgs.mkIosCmakeStage { pname; version;
  # src; sourceDir ? "."; cmakeFlags ? []; buildInputs ? []; exportedSymbols ?
  # []; exportedSymbolFiles ? []; ... }`.
  mkIosCmakeStage = final.callPackage ./cmake-stage.nix {
    inherit (final)
      xcodeClang
      logosQtCrossToolchainFile
      logosQtCrossCmakeFlags
      logosIosSymbolExports
      ;
  };

  qt6 = prev.qt6.overrideScope (
    qfinal: qprev:
    let
      mkQtModule = final.callPackage ./qt-module.nix {
        inherit (final) xcodeClang;
        inherit hostQt appleSdk arch;
        inherit (qprev) srcs;
      };
    in
    {
      qtbase = mkQtModule { pname = "qtbase"; };

      qtshadertools = mkQtModule {
        pname = "qtshadertools";
        qtDeps = [ qfinal.qtbase ];
        cmakeFlags = [
          "-DQt6ShaderToolsTools_DIR=${hostQt.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
        ];
      };

      qtsvg = mkQtModule {
        pname = "qtsvg";
        qtDeps = [ qfinal.qtbase ];
      };

      # What logos-protocol's qt_remote transport and liblogos_core link. repc
      # is a host tool, the same trap as qsb above: point at the BUILD-platform
      # Qt6RemoteObjectsTools or the configure fails with "Failed to find the
      # host tool Qt6::repc. It is part of the Qt6RemoteObjectsTools package".
      qtremoteobjects = mkQtModule {
        pname = "qtremoteobjects";
        qtDeps = [ qfinal.qtbase ];
        cmakeFlags = [
          "-DQt6RemoteObjectsTools_DIR=${hostQt.qtremoteobjects}/lib/cmake/Qt6RemoteObjectsTools"
        ];
      };

      qtdeclarative = mkQtModule {
        pname = "qtdeclarative";
        qtDeps = [
          qfinal.qtbase
          qfinal.qtshadertools
          qfinal.qtsvg
        ];
        nativeBuildInputs = [ final.pkgsBuildBuild.python3 ];
        cmakeFlags = [
          "-DPython_EXECUTABLE=${lib.getExe final.pkgsBuildBuild.python3}"
          "-DQt6QmlTools_DIR=${hostQt.qtdeclarative}/lib/cmake/Qt6QmlTools"
          "-DQt6QuickTools_DIR=${hostQt.qtdeclarative}/lib/cmake/Qt6QuickTools"
          # Qt6ShaderToolsTools (host qsb), not Qt6ShaderTools (target config):
          # without it Qt Quick is silently not built. Same trap as Windows.
          "-DQt6ShaderToolsTools_DIR=${hostQt.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
        ];
      };
    }
  );
}

// prev.lib.optionalAttrs contributesTail {
  # liblogos_core's non-Qt dependency tail, static, on Xcode's clang
  # (nix/ios/third-party.nix says why nixpkgs' own iOS stdenv is not used).
  # Sources come from the cross scope, so they stay on this flake's nixpkgs
  # pin; only the build is ours. Header-only packages are taken from the build
  # platform unchanged -- their CMake config packages carry nothing
  # platform-specific.
  inherit
    (import ./third-party.nix {
      inherit lib appleSdk arch;
      inherit (final) xcodeClang pkgsBuildBuild;
      deploymentTarget = iosDeploymentTarget;
      boostVersion = prev.boost.version;
      opensslSrc = prev.openssl.src;
      opensslVersion = prev.openssl.version;
      spdlogSrc = prev.spdlog.src;
      spdlogVersion = prev.spdlog.version;
      libsodiumSrc = prev.libsodium.src;
      libsodiumVersion = prev.libsodium.version;
    })
    spdlog
    boost
    openssl
    libsodium
    ;

  nlohmann_json = final.pkgsBuildBuild.nlohmann_json;
  cli11 = final.pkgsBuildBuild.cli11;
}
