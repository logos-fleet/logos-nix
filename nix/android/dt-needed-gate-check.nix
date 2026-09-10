# Does ./dt-needed-gate.sh still discriminate?
#
# A gate that has quietly stopped rejecting is the same silent failure it was
# written to catch, so this builds the two artifacts that bracket the rule --
# one whose every DT_NEEDED is an NDK stub, one that names a library Android
# does not ship -- and asserts the verdict on each. The rejection is asserted
# BY MESSAGE: a status-only test would pass on a syntax error too.
{
  runCommand,
  androidPkgs,
  logosAndroidDtNeededGate,
}:

let
  clang = "${androidPkgs.ndkToolchainBin}/${androidPkgs.ndkTriple}${androidPkgs.apiLevel}-clang";
in
runCommand "logos-android-dt-needed-gate-check" { } ''
  set -euo pipefail
  gate=${logosAndroidDtNeededGate}/bin/logos-android-dt-needed-gate

  mkdir -p shipped alone
  echo 'int lp_probe(void) { return 41; }' > vendor.c
  echo 'int lp_probe(void); int entry(void) { return lp_probe() + 1; }' > module.c

  # libvendor.so is a library Android has never heard of -- the stand-in for
  # every openssl/libpq/libicu a module might drag in.
  ${clang} -shared -fPIC -o shipped/libvendor.so vendor.c
  # liblog.so is in the NDK stub set, so it must never be objected to.
  ${clang} -shared -fPIC -o shipped/libmodule.so module.c \
    -Lshipped -lvendor -llog

  # 1. shipped beside its vendor library: every soname resolves on device.
  $gate shipped/libmodule.so > pass.log 2>&1 \
    || { echo "FAIL: the gate rejected a module shipped with its own libraries"; cat pass.log; exit 1; }
  grep -q "PASS" pass.log
  echo "PASS: a module beside its vendored libraries is accepted"

  # 2. the same image, alone: libvendor.so now resolves nowhere.
  cp shipped/libmodule.so alone/
  if $gate alone/libmodule.so > fail.log 2>&1; then
    echo "FAIL: the gate accepted a module whose libvendor.so is not shipped"; cat fail.log; exit 1
  fi
  grep -q "libvendor.so" fail.log \
    || { echo "FAIL: rejected, but without naming libvendor.so"; cat fail.log; exit 1; }
  echo "PASS: an unbundled soname is rejected, by name"

  # 3. --allow-dir is what an APK layout looks like: the same lone image, told
  #    where the rest of the package will sit.
  $gate --allow-dir shipped alone/libmodule.so > allow.log 2>&1 \
    || { echo "FAIL: --allow-dir did not admit the shipped directory"; cat allow.log; exit 1; }
  echo "PASS: --allow-dir admits a library packaged elsewhere"

  # 4. --allow is the same admission for ONE soname the container guarantees
  #    but does not sit beside the artifact.
  $gate --allow libvendor.so alone/libmodule.so > allow-soname.log 2>&1 \
    || { echo "FAIL: --allow did not admit a named soname"; cat allow-soname.log; exit 1; }
  echo "PASS: --allow admits a soname the container guarantees"

  # 5. an empty stub set would pass everything; refusing to gate at all is the
  #    only honest answer.
  mkdir -p no-stubs
  if LOGOS_ANDROID_STUB_LIB_DIR=$PWD/no-stubs $gate shipped/libmodule.so > empty.log 2>&1; then
    echo "FAIL: the gate ran against an empty NDK stub allowlist"; cat empty.log; exit 1
  fi
  grep -q "empty allowlist" empty.log \
    || { echo "FAIL: refused, but not for the empty allowlist"; cat empty.log; exit 1; }
  echo "PASS: an empty NDK stub set is refused rather than trusted"

  touch $out
''
