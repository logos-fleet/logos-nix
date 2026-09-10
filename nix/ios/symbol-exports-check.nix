# Does logos_ios_export_symbols() actually change the linked image?
#
# The two things it promises are invisible in a build log and only fail on a
# device, at dlopen: that `-u` pulls in an archive member nothing references,
# and that `-exported_symbols_list` narrows the export trie to the named set.
# So this links the same program twice, with and without the call, and asserts
# the difference -- a status-only test would pass on a helper that had quietly
# become a no-op.
#
# No Qt: the mechanism under test is the linker's, and staying Qt-free keeps
# this a seconds-long check rather than an hours-long one.
{
  logosIosSymbolExports,
  xcodeClang,
  pkgsBuildBuild,
}:

let
  # The one symbol the app is asked to force-load and export.
  forced = "_logos_probe_unused";
  symbolsFile = pkgsBuildBuild.writeText "logos-ios-check-symbols.txt" ''
    # comments and blank lines are dropped by the helper

    ${forced}
  '';
in
xcodeClang.mkDerivation {
  pname = "ios-symbol-exports-check";
  version = "0";
  src = ./symbol-exports-check;

  cmakeFlags = [
    "-DCMAKE_OSX_SYSROOT=iphonesimulator"
    "-DCMAKE_OSX_ARCHITECTURES=arm64"
    "-DLOGOS_IOS_CMAKE_DIR=${logosIosSymbolExports}"
    "-DLOGOS_IOS_EXPORTED_SYMBOLS_FILE=${symbolsFile}"
  ];

  postInstall = ''
    plain=$(nm -gU $out/bin/app_plain | awk '{print $NF}' | sort -u)
    list=$(nm -gU $out/bin/app_list | awk '{print $NF}' | sort -u)
    echo "app_plain exports:"; printf '%s\n' "$plain"
    echo "app_list exports:";  printf '%s\n' "$list"

    fail() { echo "error: $1" >&2; exit 1; }

    # -u: the member is in the image at all. Without the flag the linker has no
    # reason to pull probe_unused.o, which is the control below.
    nm $out/bin/app_list | grep -q ' T ${forced}$' \
      || fail "${forced} is not defined in app_list: -u did not pull its archive member in"
    nm $out/bin/app_plain | grep -q '${forced}' \
      && fail "${forced} landed in the control image, so the -u case proves nothing"

    # -exported_symbols_list: the trie is the named set and nothing else. _main
    # is reached through LC_MAIN, so an app does not have to export it.
    [ "$list" = "${forced}" ] || fail "app_list exports more than the listed set: $list"

    # The control has to export more, or narrowing it was not the reason.
    [ "$(printf '%s\n' "$plain" | grep -c .)" -gt 1 ] \
      || fail "the control exports $plain -- nothing for the list to narrow"
    printf '%s\n' "$plain" | grep -q '^_logos_probe_used$' \
      || fail "the control does not export _logos_probe_used: this is not measuring exports"

    echo "ok: -u forced ${forced} in, -exported_symbols_list kept it alone"
  '';

  meta = {
    description = "logos_ios_export_symbols() forces symbols in and narrows the export trie";
    platforms = [ "aarch64-darwin" ];
  };
}
