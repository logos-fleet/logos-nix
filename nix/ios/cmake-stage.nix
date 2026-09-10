# A CMake project built for iOS as static archives against the store Qt: the
# pure half of an app. Whatever needs Xcode's generator, code
# signing or simctl stays in an impure `nix run` on top of this.
{
  lib,
  pkgsBuildBuild,
  xcodeClang,
  qt6,
  logosQtCrossToolchainFile,
  logosQtCrossCmakeFlags,
  logosIosSymbolExports,
}:

{
  # Only ever the symbols file's name; mkDerivation still takes pname or name.
  pname ? "ios-stage",
  # sourceDir: the directory holding CMakeLists.txt, relative to src.
  sourceDir ? ".",
  cmakeFlags ? [ ],
  buildInputs ? [ ],
  postInstall ? "",
  # Symbols the app image must force-load and export so the Bare modules it
  # dlopens can resolve them upward (ADR 0006). Both end up in one file passed
  # as -DLOGOS_IOS_EXPORTED_SYMBOLS_FILE; the project feeds it to
  # logos_ios_export_symbols(SYMBOL_FILES ...) on its app target. Empty means
  # the flag is absent, not an empty list -- a stage with no Bare modules
  # should not silently start restricting its own exports.
  exportedSymbols ? [ ],
  # Files of newline-separated symbol names, e.g. a module's `nm -u` output
  # intersected with what the app defines. Usually the real source: the set is
  # a property of the module images, not something to hand-maintain here.
  exportedSymbolFiles ? [ ],
  ...
}@args:

let
  wantsExports = exportedSymbols != [ ] || exportedSymbolFiles != [ ];

  # Sorted and deduplicated here so the store path is a function of the SET,
  # not of the order two callers happened to list the same symbols in.
  symbolsFile =
    if !wantsExports then
      null
    else
      pkgsBuildBuild.runCommandLocal "${pname}-ios-exported-symbols.txt" {
        literals = lib.concatMapStrings (s: s + "\n") exportedSymbols;
        passAsFile = [ "literals" ];
      } ''
        cat "$literalsPath" ${lib.escapeShellArgs (map toString exportedSymbolFiles)} \
          | sed -e 's/#.*//' -e 's/[[:space:]]//g' \
          | grep -v '^$' | sort -u > $out
        [ -s $out ] || { echo "error: exportedSymbols/exportedSymbolFiles resolved to nothing" >&2; exit 1; }
      '';

  symbolExports = {
    cmakeDir = "${logosIosSymbolExports}";
    inherit symbolsFile;
    # What an impure Xcode configure of the same project has to repeat; the
    # app target is linked out there, so this is where the flags actually land.
    cmakeFlags = [
      "-DLOGOS_IOS_CMAKE_DIR=${logosIosSymbolExports}"
    ]
    ++ lib.optional wantsExports "-DLOGOS_IOS_EXPORTED_SYMBOLS_FILE=${symbolsFile}";
  };
in
xcodeClang.mkDerivation (
  removeAttrs args [
    "sourceDir"
    "exportedSymbols"
    "exportedSymbolFiles"
  ]
  // {
    cmakeDir = "../${sourceDir}";

    buildInputs = [
      qt6.qtbase
      qt6.qtdeclarative
      qt6.qtshadertools
      qt6.qtsvg
    ]
    ++ buildInputs;

    cmakeFlags = [
      "-DCMAKE_TOOLCHAIN_FILE=${logosQtCrossToolchainFile}"
    ]
    ++ logosQtCrossCmakeFlags
    ++ symbolExports.cmakeFlags
    ++ cmakeFlags;

    # Static is the contract: a dynamic image here is an archive
    # that silently became a plugin no iOS host can load.
    postInstall = ''
      _dynamic=$(find $out \( -name '*.dylib' -o -name '*.so' -o -name '*.framework' \))
      while IFS= read -r _f; do
        case "$_f" in *.a | *.o) continue ;; esac
        if otool -hv "$_f" 2>/dev/null | grep -qE '^\s*MH_MAGIC.*(DYLIB|BUNDLE|EXECUTE)'; then
          _dynamic="$_dynamic"$'\n'"$_f"
        fi
      done < <(find $out -type f)
      if [ -n "$_dynamic" ]; then
        echo "error: dynamic image in a static-only iOS stage:$_dynamic" >&2
        exit 1
      fi
      [ -n "$(find $out -name '*.a' -print -quit)" ] || { echo "error: no static archive installed" >&2; exit 1; }
    ''
    + postInstall;

    passthru = (args.passthru or { }) // {
      logosIosSymbolExports = symbolExports;
    };

    meta = {
      platforms = [ "aarch64-darwin" ];
    }
    // (args.meta or { });
  }
)
