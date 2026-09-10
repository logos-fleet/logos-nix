# The non-Qt dependency tail of liblogos_core as static archives for iOS,
# on Xcode's clang (xcode-clang.nix). nixpkgs' own iOS cross stdenv is not
# usable here: at this pin `pkgsIosSimulator.stdenv` fails building
# compiler-rt ("ln: failed to create symbolic link './lib': File exists")
# and targets the macOS SDK, so every archive below is built by hand.
{
  lib,
  xcodeClang,
  pkgsBuildBuild,
  appleSdk, # "iphonesimulator" | "iphoneos"
  arch, # "arm64"
  deploymentTarget, # "17"
  # Source derivations from the cross scope (same pin as the native set).
  boostVersion,
  opensslSrc,
  opensslVersion,
  spdlogSrc,
  spdlogVersion,
  libsodiumSrc,
  libsodiumVersion,
}:

let
  boostCmake = import ../boost-cmake.nix {
    inherit (pkgsBuildBuild) fetchurl;
    version = boostVersion;
  };

  # Target triple clang wants for this SDK.
  triple = "${arch}-apple-ios${deploymentTarget}" + lib.optionalString (appleSdk == "iphonesimulator") "-simulator";

  # -D flags every plain CMake project needs to target this SDK; Qt projects
  # get the same from qt.toolchain.cmake.
  cmakeTargetFlags = [
    "-DCMAKE_OSX_SYSROOT=${appleSdk}"
    "-DCMAKE_OSX_ARCHITECTURES=${arch}"
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=${deploymentTarget}"
    "-DBUILD_SHARED_LIBS=OFF"
  ];

  # For libsodium's autotools build: a compiler command line that already
  # carries the SDK and triple.
  ccEnv = ''
    export SDKROOT=$(xcrun --sdk ${appleSdk} --show-sdk-path)
    export CC="$(xcrun --sdk ${appleSdk} --find clang) -target ${triple} -isysroot $SDKROOT"
    export CXX="$(xcrun --sdk ${appleSdk} --find clang++) -target ${triple} -isysroot $SDKROOT"
    export CFLAGS="-O2"
    export CXXFLAGS="-O2"
  '';
in
{
  spdlog = xcodeClang.mkDerivation {
    pname = "spdlog-ios";
    version = spdlogVersion;
    src = spdlogSrc;
    cmakeFlags = cmakeTargetFlags ++ [
      "-DSPDLOG_BUILD_SHARED=OFF"
      "-DSPDLOG_BUILD_EXAMPLE=OFF"
      "-DSPDLOG_BUILD_TESTS=OFF"
      "-DSPDLOG_INSTALL=ON"
      "-DSPDLOG_FMT_EXTERNAL=OFF"
    ];
  };

  # Boost through its own CMake build (../boost-cmake.nix, shared with the
  # Android tail), static.
  boost = xcodeClang.mkDerivation {
    pname = "boost-ios";
    version = boostVersion;
    inherit (boostCmake) src postInstall;
    # Boost.Process v2's shell parser is wordexp(3), which the iOS SDK marks
    # unavailable ("'wordexp' is unavailable: not available on iOS"); take
    # the ENOTSUP branch it already has for OpenBSD/Android. iOS-only set, so
    # matching on __APPLE__ is exact here.
    postPatch = ''
      substituteInPlace libs/process/src/shell.cpp \
        --replace-fail '!defined(__OpenBSD__) && !defined(__ANDROID__)' \
                       '!defined(__OpenBSD__) && !defined(__ANDROID__) && !defined(__APPLE__)'
    '';
    cmakeFlags = cmakeTargetFlags ++ boostCmake.cmakeFlags ++ [
      "-DBOOST_RUNTIME_LINK=static"
    ];
  };

  # OpenSSL's own Configure knows the iOS SDKs; it shells out to xcrun, which
  # the version-gated wrapper provides.
  openssl = xcodeClang.mkDerivation {
    pname = "openssl-ios";
    version = opensslVersion;
    src = opensslSrc;
    nativeBuildInputs = [ pkgsBuildBuild.perl ];
    dontUseCmakeConfigure = true;
    configurePhase = ''
      runHook preConfigure
      export SDKROOT=$(xcrun --sdk ${appleSdk} --show-sdk-path)
      perl ./Configure ${if appleSdk == "iphonesimulator" then "iossimulator-arm64-xcrun" else "ios64-xcrun"} \
        no-shared no-tests no-apps no-docs no-module no-dso \
        ${if appleSdk == "iphonesimulator" then "-mios-simulator-version-min" else "-mios-version-min"}=${deploymentTarget} \
        --prefix=$out --openssldir=$out/etc/ssl --libdir=lib
      runHook postConfigure
    '';
    buildPhase = ''
      runHook preBuild
      make -j''${NIX_BUILD_CORES:-8} build_libs
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      make install_dev
      runHook postInstall
    '';
  };

  libsodium = xcodeClang.mkDerivation {
    pname = "libsodium-ios";
    version = libsodiumVersion;
    src = libsodiumSrc;
    nativeBuildInputs = [ pkgsBuildBuild.autoreconfHook ];
    dontUseCmakeConfigure = true;
    dontUseNinjaBuild = true;
    dontUseNinjaInstall = true;
    # libsodium's configure probes the SDK's target; the host triple is what
    # config.sub accepts, the -target in CC is what actually selects iOS.
    preConfigure = ccEnv;
    configureFlags = [
      "--host=aarch64-apple-darwin"
      "--disable-shared"
      "--enable-static"
      "--disable-ssp"
      "--disable-asm"
      "--with-pic"
    ];
  };
}
