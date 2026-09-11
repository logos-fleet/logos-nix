# EMSCRIPTEN, PINNED — the one toolchain every Logos wasm32 artifact is built
# with.
#
# It has to be one, and named in one place, for the same reason the iOS Xcode
# version is: a wasm host links a C++ image (logos-protocol's web transport) to
# a module core that may have been compiled by a DIFFERENT language's toolchain
# (Rust via `wasm32-unknown-emscripten`). Emscripten's ABI is not stable across
# releases — the libc++ layout, the `__wasm_call_ctors` scheme and the JS glue's
# runtime contract all move — so "whatever emcc the consumer happened to have"
# is a silent mislink waiting for a minor bump. `logosEmscriptenVersion` is what
# a Rust or Nim backend pins its own emsdk against.
#
# WHY A SHELL SNIPPET AND NOT JUST A PACKAGE. emcc writes to its cache the first
# time it needs a build of libc/libc++ in a configuration the store copy does
# not have (a `-O2` link wants the non-debug variants, and nixpkgs ships the
# debug ones), and the store copy is read-only. Every consumer would otherwise
# rediscover that, and rediscover it as "Permission denied" from inside a python
# traceback. So the copy-and-chmod is written once, here.
#
# ADDS ATTRIBUTES ONLY. Nothing existing is overridden, so putting this overlay
# on a native package set cannot change any other derivation's hash.
final: prev:

let
  inherit (prev) lib;
  emscripten = prev.emscripten;
in
{
  logosEmscripten = emscripten;

  # The pin, as data. A backend that drives its own toolchain installer (rustup
  # targets, an emsdk checkout) matches on this rather than on a store path.
  logosEmscriptenVersion = emscripten.version;

  # Put emcc on PATH with a WRITABLE cache seeded from the store one.
  #
  # Run it in preConfigure (cmake probes the compiler) or at the top of a hand-
  # rolled buildPhase. `$TMPDIR` rather than `$PWD`: a cmake build tree gets
  # copied around by some of our derivations and an 84 MB cache travelling with
  # it is pure cost.
  #
  # EM_CONFIG is set to the store's `.emscripten`, whose EMSCRIPTEN_ROOT /
  # LLVM_ROOT / BINARYEN_ROOT already point into the store. Only the cache moves.
  logosEmscriptenSetup = ''
    export EM_CONFIG=${emscripten}/share/emscripten/.emscripten
    export EM_CACHE="$TMPDIR/logos-em-cache"
    if [ ! -d "$EM_CACHE" ]; then
      cp -R ${emscripten}/share/emscripten/cache "$EM_CACHE"
      chmod -R u+w "$EM_CACHE"
    fi
    export PATH=${emscripten}/bin:$PATH
    # Nothing Logos builds uses an emscripten PORT (SDL, zlib, ...), and a port
    # is the only thing in this toolchain that would reach the network. Say so,
    # so a build that grows one fails in the sandbox rather than depending on
    # whoever's machine has the tarball cached.
    export EMSDK_QUIET=1
  '';

  # The toolchain file cmake needs to target wasm32. Named rather than
  # interpolated at each call site because `Emscripten.cmake` moved once already
  # in emsdk's history.
  logosWasmCmakeToolchain =
    "${emscripten}/share/emscripten/cmake/Modules/Platform/Emscripten.cmake";

  logosWasmCmakeFlags = [
    "-DCMAKE_TOOLCHAIN_FILE=${final.logosWasmCmakeToolchain}"
  ];
}
