# One Qt module for iOS as static frameworks, on Xcode's own toolchain
# (xcode-clang.nix says why not nix's cc-wrapper).
{
  lib,
  xcodeClang,
  hostQt, # build-platform qt6 scope at the same pin; supplies moc/rcc/qsb/...
  srcs, # the cross scope's srcs.nix
  appleSdk, # "iphonesimulator" | "iphoneos"
  arch, # CMAKE_OSX_ARCHITECTURES
}:

{
  pname,
  # iOS-built Qt modules this one links against; also propagated to consumers
  # so a single buildInputs entry pulls the whole static set.
  qtDeps ? [ ],
  nativeBuildInputs ? [ ],
  cmakeFlags ? [ ],
  # nixpkgs' patch set for the same source, minus the PATH-based plugin
  # lookup: it needs a NIXPKGS_QT_PLUGIN_PREFIX define only the cc-wrapper
  # injects, and dynamic plugin lookup is moot in a static build.
  patches ? builtins.filter (
    p: !(lib.hasSuffix "derive-plugin-load-path-from-PATH.patch" (baseNameOf (toString p)))
  ) (hostQt.${pname}.patches or [ ]),
  ...
}@args:

let
  inherit (srcs.${pname}) src version;
  qtPluginPrefix = "lib/qt-6/plugins";
  qtQmlPrefix = "lib/qt-6/qml";
  isQtbase = pname == "qtbase";
  qtbase = lib.findFirst (d: d.pname == "qtbase") null qtDeps;

  # reduce_exports=OFF is necessary but not sufficient. qmetatype.h wraps the
  # QMetaTypeInterfaceWrapper<T>::metaType definitions in an UNCONDITIONAL
  # `#pragma GCC visibility push(hidden)` on every non-Windows clang target,
  # reasoning that "each library is going to have a copy anyway" -- true of a
  # shared build, false here: the same header declares
  #   extern template struct Q_CORE_EXPORT QMetaTypeInterfaceWrapper<QString>;
  # for every builtin type, so a Bare module does NOT instantiate its own and
  # instead references qtbase's, which the pragma has made unexportable. Any
  # module with a QString Q_PROPERTY or signal hits it. Measured on the spike's
  # SpikeUi against a reduce_exports=OFF Qt, no visibility patch:
  #   dlopen(...SpikeUi): symbol not found in flat namespace
  #     '__ZN9QtPrivate25QMetaTypeInterfaceWrapperI7QStringE8metaTypeE'
  # push(default) leaves the pragma's `pop` balanced and touches nothing
  # outside those declarations. --replace-fail so a Qt bump that moves or
  # rewords the pragma fails the build instead of silently shipping a Qt whose
  # modules cannot load. The ios-qt-exports check asserts the resulting symbol.
  #
  # The alternative -- every module compiled with Qt's private
  # QT_NO_DATA_RELOCATION so it instantiates its own hidden copy -- was
  # measured to work too (it trades the 2 symbols for 5 ordinary QtCore ones),
  # but it puts a Qt-internal define in every module recipe and gives each
  # module its own QMetaTypeInterface objects, which is not the one-canonical-
  # copy shape ADR 0006 asks for.
  metaTypeVisibility = ''
    substituteInPlace src/corelib/kernel/qmetatype.h \
      --replace-fail '#  pragma GCC visibility push(hidden)' \
                     '#  pragma GCC visibility push(default)'
  '';
in
xcodeClang.mkDerivation (
  removeAttrs args [ "qtDeps" ]
  // {
    inherit
      pname
      version
      src
      patches
      nativeBuildInputs
      ;

    propagatedBuildInputs = qtDeps;

    cmakeFlags = [
      "--log-level=STATUS"
      "-DCMAKE_OSX_ARCHITECTURES=${arch}"
      "-DQT_HOST_PATH=${hostQt.qtbase}"
      "-DQt6HostInfo_DIR=${hostQt.qtbase}/lib/cmake/Qt6HostInfo"
      "-DQT_BUILD_EXAMPLES=OFF"
      "-DQT_BUILD_TESTS=OFF"
      "-DQT_GENERATE_SBOM=OFF"
      # never pick up build-platform .pc files for the iOS host
      "-DFEATURE_pkg_config=OFF"
    ]
    ++ (
      if isQtbase then
        [
          "-DQT_QMAKE_TARGET_MKSPEC=macx-ios-clang"
          "-DQT_APPLE_SDK=${appleSdk}"
          "-DINSTALL_PLUGINSDIR=${qtPluginPrefix}"
          "-DINSTALL_QMLDIR=${qtQmlPrefix}"
          # A Bare module is dlopened into the app and resolves Qt UPWARD, out
          # of the app image (ADR 0006). With reduce_exports on, every Qt
          # target is built -fvisibility=hidden, so the static archives carry
          # their API as `private external`; the static linker turns those into
          # local symbols and the app image exports no Qt at all. dlopen then
          # dies on the first Qt symbol:
          #   symbol not found in flat namespace '__ZN10QByteArray6_emptyE'
          # Off here is what makes the app able to export Qt; WHICH symbols it
          # actually exports is the app's `-exported_symbols_list` (see
          # nix/ios/LogosIosSymbolExports.cmake) — this flag alone costs the app
          # nothing until it links.
          #
          # qtbase only: the feature is recorded on the Qt6::Core target
          # (QT_ENABLED_PUBLIC_FEATURES / QT_ENABLED_PRIVATE_FEATURES in
          # Qt6CoreTargets.cmake) and imported by every repo built against it,
          # so qtdeclarative, qtsvg and qtshadertools inherit it. The
          # ios-qt-exports check asserts that inheritance on the real binaries
          # rather than trusting it.
          "-DFEATURE_reduce_exports=OFF"
        ]
      else
        [
          "-DCMAKE_TOOLCHAIN_FILE=${qtbase}/lib/cmake/Qt6/qt.toolchain.cmake"
          "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH=${lib.concatStringsSep ";" (map toString qtDeps)}"
        ]
    )
    ++ cmakeFlags;

    postPatch = lib.optionalString isQtbase metaTypeVisibility + (args.postPatch or "");

    passthru = (args.passthru or { }) // {
      inherit qtPluginPrefix qtQmlPrefix appleSdk;
    };

    meta = {
      homepage = "https://www.qt.io/";
      description = "Qt ${pname} ${version} for iOS (${appleSdk}, static frameworks)";
      license = with lib.licenses; [
        fdl13Plus
        gpl2Plus
        lgpl21Plus
        lgpl3Plus
      ];
      platforms = lib.platforms.darwin;
    }
    // (args.meta or { });
  }
)
