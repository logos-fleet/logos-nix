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
  # The two spellings of `rustTarget` that appear in environment variable
  # names: cargo keys CARGO_TARGET_<T>_* off the triple with dashes turned into
  # underscores and upper-cased, cc-rs keys CC_/CXX_/AR_/CFLAGS_ off the same
  # triple lower-cased.
  rustTargetVar = builtins.replaceStrings [ "-" ] [ "_" ] rustTarget;
  rustTargetVarUpper = lib.toUpper rustTargetVar;

  # Resolving the toolchain out of Xcode, shared by the Rust and Nim setups.
  # BY ABSOLUTE PATH, with DEVELOPER_DIR passed per invocation: putting
  # xcodeWrapper on PATH or exporting SDKROOT would also reach any BUILD-platform
  # compile happening in the same shell -- see logosRustCrossSetup for what that
  # costs.
  #
  # Two spellings of that, for two kinds of caller. `xcrunShim` is `xcrun` and
  # only `xcrun`, on PATH, with DEVELOPER_DIR baked into the invocation -- for a
  # build script that reaches for it by name (see logosRustCrossSetup).
  xcrunShim = final.pkgsBuildBuild.writeShellScriptBin "xcrun" ''
    exec env DEVELOPER_DIR="${final.xcodeWrapper.developerDir}" /usr/bin/xcrun "$@"
  '';

  # `xcrunPreamble` is the shell-function form, for the setup snippets below.
  xcrunPreamble = ''
    _xcrun() { DEVELOPER_DIR="${final.xcodeWrapper.developerDir}" ${final.xcodeWrapper}/bin/xcrun --sdk ${appleSdk} "$@"; }
    _sdkroot="$(_xcrun --show-sdk-path)"
    [ -d "$_sdkroot" ] || { echo "logos-nix: xcrun could not resolve the ${appleSdk} SDK: $_sdkroot" >&2; exit 1; }
  '';
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
  # consumer writes one code path for both. Deliberately does NOT need
  # xcodeWrapper on PATH -- see the body.
  logosRustCrossTarget = lib.optionalString isCross rustTarget;
  logosRustCrossSetup = lib.optionalString isCross ''
    # Nothing here touches the process environment the BUILD half runs in, and
    # that is the whole design. One cargo run compiles this crate's build
    # scripts and proc macros for the build platform and the crate itself for
    # the target, so anything process-wide reaches both:
    #   * exporting SDKROOT=<iPhone SDK> makes the host half link against it
    #     (measured: `quote`'s build script, "symbol(s) not found for
    #     architecture arm64" while building for macOS);
    #   * putting xcodeWrapper on PATH shadows nixpkgs' clang/ar/ranlib/nm with
    #     Xcode's for the host half too, with the same shape of failure.
    # So every result below is keyed to the TARGET triple, and xcrun is reached
    # the way xcrunPreamble describes.
    ${xcrunPreamble}
    _clang="$(_xcrun --find clang)"
    _clangxx="$(_xcrun --find clang++)"

    # ONE BINARY ON PATH, and it is `xcrun` -- not the wrapper, and not
    # DEVELOPER_DIR in the environment.
    #
    # A crate whose build script compiles bundled C (aws-lc-sys, ring,
    # zstd-sys) goes through cc-rs, and cc-rs resolves the Apple SDK by running
    # plain `xcrun --show-sdk-path --sdk iphoneos` ITSELF. It has never heard of
    # CC_<target> or CFLAGS_<target>, so nothing below reaches it, and inside a
    # nix build that xcrun exits 255 -- surfacing as "error occurred in cc-rs:
    # command did not execute successfully" naming the build script and nothing
    # else. (Measured on chat_module's aws-lc-sys v0.41.0 for aarch64-apple-ios.)
    #
    # Exporting DEVELOPER_DIR instead is the obvious fix and is WRONG, for the
    # reason above: it is process-wide, and nixpkgs' own darwin cc wrapper
    # resolves its sysroot through the same Xcode selection, so the BUILD half
    # starts linking against the iPhone SDK -- measured as `quote`'s build
    # script, "Undefined symbols for architecture arm64: __NSGetEnviron, _write,
    # _pthread_*" on a plain `-lSystem -mmacosx-version-min=11.3.0` link line.
    # The shim carries DEVELOPER_DIR to the one child that needs it and to no
    # other, and shadows no compiler.
    export PATH="${xcrunShim}/bin:$PATH"

    export CARGO_BUILD_TARGET=${rustTarget}
    # Both halves are needed: without the cc-rs one a build script compiles its
    # bundled C for the BUILDER and the link fails on undefined symbols --
    # silently, because the archive is still produced.
    export CARGO_TARGET_${rustTargetVarUpper}_LINKER="$_clang"
    # rustc would normally read the SDK out of SDKROOT; it is not exported, so
    # the target link is told where it is directly.
    export CARGO_TARGET_${rustTargetVarUpper}_RUSTFLAGS="-Clink-arg=-isysroot -Clink-arg=$_sdkroot -Clink-arg=--target=${triple}"
    export CC_${rustTargetVar}="$_clang"
    export CXX_${rustTargetVar}="$_clangxx"
    export AR_${rustTargetVar}="$(_xcrun --find ar)"
    # `--target=<triple>`, ONE WORD, never `-target <triple>`. clang accepts
    # both, but these flags do not stop at clang: cc-rs hands CFLAGS_<target>
    # to whatever build system a -sys crate drives, and a bare `${triple}`
    # sitting on its own is then read as a positional argument. openssl-src
    # does exactly that -- its ./Configure takes the target name positionally,
    # already has `ios64-cross`, and dies with "target already defined -
    # ios64-cross (offending arg: arm64-apple-ios17)". A single word beginning
    # with `-` passes through every such wrapper untouched.
    export CFLAGS_${rustTargetVar}="--target=${triple} -isysroot $_sdkroot"
    export CXXFLAGS_${rustTargetVar}="--target=${triple} -isysroot $_sdkroot"
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
    ${xcrunPreamble}
    nimFlagsArray+=(
      "--clang.exe=$(_xcrun --find clang)"
      "--clang.cpp.exe=$(_xcrun --find clang++)"
      "--clang.linkerexe=$(_xcrun --find clang)"
      "--clang.cpp.linkerexe=$(_xcrun --find clang++)"
      "--passC:-target ${triple}"
      "--passC:-isysroot $_sdkroot"
      "--passL:-target ${triple}"
      "--passL:-isysroot $_sdkroot"
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
