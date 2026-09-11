# QT FOR WEBASSEMBLY, FROM SOURCE — the QML runtime the Web container serves.
#
# WHY FROM SOURCE AND NOT A KIT. The spike (docs/research/spikes/
# qt-wasm-in-wkwebview.md, in logos-workspace) used the Qt online installer's
# `wasm_singlethread` kit. A kit cannot be an input to a Logos build: it is not
# addressable, it is not the Qt this workspace pins for every other target, and
# its emsdk is whatever the installer chose — while a wasm artifact in this
# platform links a C++ image built by THIS repo's emscripten pin (nix/wasm/
# overlay.nix) next to it. Building Qt here makes the runtime's Qt version and
# its emsdk the same two pins every other wasm artifact already names.
#
# WHY NOT A nixpkgs CROSS PACKAGE SET, the way iOS/Android/Windows Qt is done in
# this repo: there is no Emscripten cross set in nixpkgs (README, "Wasm target"
# — emscripten brings its own sysroot, libc and libc++, and `pkgsCross.wasi32`
# is a different target that cannot link the JS glue a browser host needs). So
# this file does what that section prescribes: drives `emcc` from ordinary
# native derivations. The SHAPE, though, is lifted from nix/ios/qt-module.nix —
# same host-tool flags, same `qt.toolchain.cmake` chainload for the non-qtbase
# modules — because the problem a cross Qt build poses is the same everywhere:
# every code generator (moc, rcc, qmlcachegen, qsb, repc) must come from a
# BUILD-platform Qt of the exact same version, and naming only QT_HOST_PATH
# gets you a configure that cannot find the one tool your module happens to
# need.
#
# SINGLE-THREADED, and that is a decision, not a default we inherited: ADR 0004
# budgets one live runtime per app at ~26 MB / ~200 MB renderer, and threads in
# a webview need `crossOriginIsolated`, which the spike measured as
# unobtainable on Android WebView and obtainable on iOS only from a loopback
# server. `QT_FEATURE_thread=OFF` is therefore passed explicitly rather than
# left to the platform default, so a Qt bump that flips that default shows up
# here as a diff.
{
  lib,
  # Native package set carrying THE EMSCRIPTEN PIN: logosEmscriptenSetup (emcc
  # on PATH with a writable cache, EMSDK pointing at the emsdk-shaped view) and
  # logosWasmCmakeToolchain. Deliberately NOT the same pin as `hostQt`: the
  # emsdk is shared with logos-protocol's wasm build and the module hosts, the
  # Qt version is shared with the mobile and Windows targets, and the two pins
  # move for different reasons.
  pkgs,
  # Build-platform qt6 scope at the version being built here. Supplies both the
  # host tools and the sources: its version IS this build's version, because Qt
  # refuses a host path whose version differs from the target's, and taking the
  # sources from the same scope is what makes that true by construction rather
  # than by two pins agreeing.
  qt6,
}:

let
  hostQt = qt6;
  inherit (qt6) srcs;
  version = srcs.qtbase.version;

  # nixpkgs' patch set for the same source, minus the PATH-based plugin lookup:
  # it needs a NIXPKGS_QT_PLUGIN_PREFIX define only the cc-wrapper injects, and
  # there is no plugin lookup at all in a statically linked wasm image. Same
  # exclusion, for the same reason, as nix/ios/qt-module.nix.
  patchesFor =
    pname:
    builtins.filter (
      p: !(lib.hasSuffix "derive-plugin-load-path-from-PATH.patch" (baseNameOf (toString p)))
    ) (hostQt.${pname}.patches or [ ]);

  # Features off. Every one of these is a module that would be compiled, linked
  # and installed for a target that cannot use it, and wasm build time is the
  # scarcest thing about this derivation.
  #
  # `thread` is the load-bearing one (see the header). The rest are absence of
  # use: the Web container's runtime is Qt Quick + the design system; there is
  # no QWidget in a canvas, no printer, no SQL driver and no D-Bus bus in a
  # browser tab.
  disabledFeatures = [
    "-DQT_FEATURE_thread=OFF"
    "-DQT_FEATURE_widgets=OFF"
    "-DQT_FEATURE_printsupport=OFF"
    "-DQT_FEATURE_sql=OFF"
    "-DQT_FEATURE_dbus=OFF"
  ];

  mkQtWasmModule =
    {
      pname,
      # wasm-built Qt modules this one links against; propagated so one
      # buildInputs entry pulls the whole static set.
      qtDeps ? [ ],
      nativeBuildInputs ? [ ],
      cmakeFlags ? [ ],
      ...
    }@args:
    let
      isQtbase = pname == "qtbase";
      qtbase = lib.findFirst (d: d.pname == "qtbase") null qtDeps;
      depIncludeFlags = lib.concatMapStringsSep " " (d: "-isystem ${d}/include") qtDeps;
      allFlags = [
        "--log-level=STATUS"
        "-DCMAKE_BUILD_TYPE=Release"
        "-DCMAKE_INSTALL_PREFIX=${placeholder "out"}"
        "-DQT_HOST_PATH=${hostQt.qtbase}"
        "-DQt6HostInfo_DIR=${hostQt.qtbase}/lib/cmake/Qt6HostInfo"
        "-DQT_BUILD_EXAMPLES=OFF"
        "-DQT_BUILD_TESTS=OFF"
        "-DQT_GENERATE_SBOM=OFF"
        # Never let the build platform's .pc files answer for the wasm target.
        "-DFEATURE_pkg_config=OFF"
      ]
      ++ (
        if isQtbase then
          [
            # The mkspec is what switches Qt into its wasm support at all:
            # qt_auto_detect_wasm() only runs for this value, and it is what
            # makes the build static (Qt for wasm has no shared build).
            "-DQT_QMAKE_TARGET_MKSPEC=wasm-emscripten"
          ]
          ++ disabledFeatures
        else
          [
            # qtbase's own toolchain file, not the emscripten one directly: it
            # chainloads Emscripten.cmake AND replays the target's Qt settings,
            # so a module cannot silently configure for a different wasm Qt
            # than the one it links.
            "-DCMAKE_TOOLCHAIN_FILE=${qtbase}/lib/cmake/Qt6/qt.toolchain.cmake"
            "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH=${lib.concatStringsSep ";" (map toString qtDeps)}"
            # WHAT THE cc-WRAPPER WOULD HAVE DONE. A Qt module's generated
            # `<Module>Depends` header includes the aggregate header of every
            # module it depends on (`#include <QtSvg/QtSvg>`), and nothing in
            # cmake puts that on the include path: the dependency is a link-time
            # property of a DIFFERENT target, and the Depends header gets pulled
            # into an unrelated target's precompiled header. nixpkgs' native Qt
            # builds get away with it because nix's cc-wrapper adds `-isystem`
            # for every buildInput; emcc has no wrapper, so the prefixes are
            # named here. Measured: without it, qtdeclarative 6.11.1 fails at
            # QuickVectorImageHelpers' PCH with "'QtSvg/QtSvg' file not found"
            # after ~2800 of 3460 objects.
            "-DCMAKE_CXX_FLAGS=${depIncludeFlags}"
            "-DCMAKE_C_FLAGS=${depIncludeFlags}"
          ]
      )
      ++ cmakeFlags;
    in
    pkgs.stdenv.mkDerivation (
      removeAttrs args [ "qtDeps" ]
      // {
        inherit pname version;
        inherit (srcs.${pname}) src;
        patches = args.patches or patchesFor pname;

        nativeBuildInputs = [
          pkgs.cmake
          pkgs.ninja
          pkgs.perl
        ]
        ++ nativeBuildInputs;

        propagatedBuildInputs = qtDeps;

        # cmake's nix hook is for native builds: it injects the build
        # platform's CMAKE_OSX_SYSROOT / compiler and would configure this for
        # the Mac it runs on. The toolchain file is the whole point here, so
        # the configure is hand-rolled — the same call shape as
        # logos-module-builder's buildWebModule.nix.
        dontUseCmakeConfigure = true;
        dontWrapQtApps = true;
        # A wasm archive is not a Mach-O or an ELF: `strip` cannot read one and
        # there is nothing for the fixup phase to rewrite.
        dontStrip = true;
        dontFixup = true;

        configurePhase = ''
          runHook preConfigure
          ${pkgs.logosEmscriptenSetup}
          cmake -S . -B build -GNinja ${lib.escapeShellArgs allFlags}
          runHook postConfigure
        '';

        buildPhase = ''
          runHook preBuild
          ${pkgs.logosEmscriptenSetup}
          cmake --build build --parallel $NIX_BUILD_CORES
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          ${pkgs.logosEmscriptenSetup}
          cmake --install build
          runHook postInstall
        '';

        passthru = (args.passthru or { }) // {
          isQtWasm = true;
          # The configure line, as data. The configure is hand-rolled (see
          # dontUseCmakeConfigure above), so there is no `cmakeFlags` attribute
          # for a gate to read — and the two traps this file documents (a host
          # tool flag pointing at the TARGET package, a mkspec that silently
          # stops being wasm) are both invisible until something tries to run
          # the image. checks.<system>.qt-wasm-shape reads this.
          wasmCmakeFlags = allFlags;
        };

        meta = {
          homepage = "https://www.qt.io/";
          description = "Qt ${pname} ${version} for WebAssembly (single-threaded, static)";
          license = with lib.licenses; [
            fdl13Plus
            gpl2Plus
            lgpl21Plus
            lgpl3Plus
          ];
          platforms = lib.platforms.unix;
        }
        // (args.meta or { });
      }
    );

  qtbase = mkQtWasmModule { pname = "qtbase"; };

  # qsb is a HOST tool and the flag that names it is Qt6ShaderToolsTools, not
  # Qt6ShaderTools. Getting that wrong does not fail the configure — it
  # silently drops Qt Quick from qtdeclarative, which is the same trap the iOS
  # and Windows overlays in this repo document.
  qtshadertools = mkQtWasmModule {
    pname = "qtshadertools";
    qtDeps = [ qtbase ];
    cmakeFlags = [
      "-DQt6ShaderToolsTools_DIR=${hostQt.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
    ];
  };

  # The design system's icons are SVG, so this is not optional for "renders
  # with the Logos look".
  qtsvg = mkQtWasmModule {
    pname = "qtsvg";
    qtDeps = [ qtbase ];
  };

  # QtRO is how the runtime reaches a module's backend (ADR 0004): the replica
  # side lives in this image. repc is a host tool, same trap as qsb.
  qtremoteobjects = mkQtWasmModule {
    pname = "qtremoteobjects";
    qtDeps = [ qtbase ];
    cmakeFlags = [
      "-DQt6RemoteObjectsTools_DIR=${hostQt.qtremoteobjects}/lib/cmake/Qt6RemoteObjectsTools"
    ];
  };

  qtdeclarative = mkQtWasmModule {
    pname = "qtdeclarative";
    qtDeps = [
      qtbase
      qtshadertools
      qtsvg
    ];
    nativeBuildInputs = [ pkgs.python3 ];
    cmakeFlags = [
      "-DPython_EXECUTABLE=${lib.getExe pkgs.python3}"
      "-DQt6QmlTools_DIR=${hostQt.qtdeclarative}/lib/cmake/Qt6QmlTools"
      "-DQt6QuickTools_DIR=${hostQt.qtdeclarative}/lib/cmake/Qt6QuickTools"
      "-DQt6ShaderToolsTools_DIR=${hostQt.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
    ];
  };

  modules = {
    inherit
      qtbase
      qtshadertools
      qtsvg
      qtremoteobjects
      qtdeclarative
      ;
  };

  # The BUILD-platform Qt prefixes a consumer's code generators come out of.
  hostPrefixPath = lib.concatStringsSep ";" (
    map (m: "${hostQt.${m}}") [
      "qtbase"
      "qtdeclarative"
      "qtshadertools"
      "qtsvg"
      "qtremoteobjects"
    ]
  );

  # ONE PREFIX for consumers. A wasm Qt is five store paths, and a consumer
  # that has to name all five (in CMAKE_PREFIX_PATH *and* in
  # CMAKE_FIND_ROOT_PATH, because Emscripten.cmake sets
  # CMAKE_FIND_ROOT_PATH_MODE_PACKAGE to ONLY) gets it wrong once per repo.
  prefix = pkgs.symlinkJoin {
    name = "qt-wasm-${version}";
    paths = lib.attrValues modules;
    passthru = modules // {
      inherit version;
      emscriptenVersion = pkgs.logosEmscriptenVersion;
    };
  };
in
modules
// {
  inherit prefix version;

  # What a consumer puts on its cmake line to build a wasm app against this Qt.
  # qt.toolchain.cmake rather than Emscripten.cmake: it chainloads the latter
  # and carries the target Qt's own settings with it.
  cmakeFlags = [
    "-DCMAKE_TOOLCHAIN_FILE=${qtbase}/lib/cmake/Qt6/qt.toolchain.cmake"
    "-DCMAKE_MAKE_PROGRAM=${pkgs.ninja}/bin/ninja"
    "-DCMAKE_PREFIX_PATH=${prefix}"
    "-DCMAKE_FIND_ROOT_PATH=${prefix}"
    # NOT REDUNDANT with the prefix path. Qt6Config resolves a component's
    # config against the prefix qtbase was installed into, and qtbase here is
    # one store path while Qt6Qml is another, so find_package(Qt6 COMPONENTS Qml)
    # fails with "Expected Config file at <qtbase>/lib/cmake/Qt6Qml ... does NOT
    # exist" even though the joined prefix on CMAKE_PREFIX_PATH has it. This is
    # the variable Qt provides for exactly that split, and it is what nixpkgs'
    # own qt6 setup hook sets for native consumers.
    "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH=${prefix}"
    # And the HOST half of the same split. A consumer with a QML module runs
    # qmlcachegen / qmltyperegistrar (Qt6QmlTools), qsb (Qt6ShaderToolsTools)
    # and possibly repc, all of which are BUILD-platform packages that do not
    # live in QT_HOST_PATH — it is the host *qtbase* and nothing else. Without
    # this, find_package(Qt6 COMPONENTS Qml) gets as far as finding
    # Qt6QmlConfig.cmake and then fails inside it. Same two flags, same reason,
    # as nix/ios/cross-overlay.nix's logosQtCrossCmakeFlags.
    "-DQT_HOST_PATH=${hostQt.qtbase}"
    "-DQT_ADDITIONAL_HOST_PACKAGES_PREFIX_PATH=${hostPrefixPath}"
  ];
}
