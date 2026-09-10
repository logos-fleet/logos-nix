# Did reduce_exports=OFF actually reach the binaries?
#
# The flag is a Qt feature name, so a rename or a typo is accepted in silence
# and the Qt that comes out is byte-for-byte the hidden one. It is also set on
# qtbase alone and inherited by the other repos through Qt6::Core's
# QT_ENABLED_*_FEATURES, which is an implementation detail of Qt's build that
# could change under a bump. Both are only observable in the Mach-O symbol
# table, so that is what this reads.
#
# The canary is the symbol the spike's Level 2 actually died on:
#   dlopen(...SpikeUi): symbol not found in flat namespace '__ZN10QByteArray6_emptyE'
{
  lib,
  runCommandLocal,
  qtbase,
  qtdeclarative,
  xcodeWrapper,
  label, # "simulator" | "device"
}:

let
  # The symbol Level 2 died on before reduce_exports was turned off.
  canary = "__ZN10QByteArray6_emptyE";
  # And the one it died on after, which the qmetatype.h pragma hides on its
  # own (see nix/ios/qt-module.nix). A module with a QString property needs it.
  metaTypeCanary = "__ZN9QtPrivate25QMetaTypeInterfaceWrapperI7QStringE8metaTypeE";
in
runCommandLocal "ios-qt-exports-${label}"
  {
    __noChroot = true;
    nativeBuildInputs = [ xcodeWrapper ];
    meta = {
      description = "iOS Qt (${label}) carries its API as exportable symbols";
      platforms = [ "aarch64-darwin" ];
    };
  }
  ''
    fail() { echo "error: $1" >&2; exit 1; }

    # A defined symbol that is `private external` becomes local when the app
    # links the archive, so it can never be in the app's export trie.
    check() { # name path symbol
      local name=$1 image=$2 symbol=$3 hidden total
      nm -m "$image" | grep -v '(undefined)' | grep -E "external $symbol\$" > sym.txt \
        || fail "$name does not define $symbol at all -- the check is aimed at the wrong symbol"
      if grep -q 'private external' sym.txt; then
        fail "$name still hides $symbol; reduce_exports did not reach it: $(cat sym.txt)"
      fi
      hidden=$(nm -m "$image" | grep -v '(undefined)' | grep -c 'private external' || true)
      total=$(nm -gU "$image" | grep -c . || true)
      echo "$name: $hidden of $total defined globals hidden"
      # Measured on 6.11.1, identical for both SDKs: QtCore 16851 of 17364
      # hidden with reduce_exports on, 2646 of 17111 with it off, 932 of 17111
      # with the qmetatype.h pragma neutralised too; QtQml 23867 of 37570 ->
      # 4922 of 24094 -> 2809 of 24094. What is left is Q_DECL_HIDDEN by hand
      # (moc's qt_static_metacall) and the bundled 3rdparty libraries, which
      # carry their own visibility flags. A third is well clear of every one
      # of those, so this catches the regression without pinning a count.
      [ "$total" -gt 0 ] && [ $((hidden * 3)) -lt "$total" ] \
        || fail "$name still hides $hidden of $total defined globals"
    }

    check QtCore ${qtbase}/lib/QtCore.framework/QtCore '${canary}'
    check QtCore ${qtbase}/lib/QtCore.framework/QtCore '${metaTypeCanary}'
    # qtdeclarative is a separate repo build: this is the inheritance assertion.
    check QtQml ${qtdeclarative}/lib/QtQml.framework/QtQml '__ZN10QQmlEngineC1EP7QObject'

    echo ok > $out
  ''
