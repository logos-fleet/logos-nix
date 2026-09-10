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
