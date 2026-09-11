# THE QT-WASM QML RUNTIME, PROVEN BY USE, AND WEIGHED.
#
# The Qt-for-wasm derivations next door install static archives. An archive that
# installs is not a runtime: what a consumer needs to know is that a Qt Quick
# application LINKS against this Qt, that the link produces the three files a
# webview loads (`.wasm`, `.js`, `.html`), and what that image WEIGHS — ADR
# 0004's whole budget (one live runtime per app, ~200 MB renderer) hangs off the
# size number, and the brotli number is what an in-app server would actually
# send (spike recommendation 2).
#
# So this derivation builds the smallest application that is still the runtime's
# shape (Quick + Controls + Svg + RemoteObjects, see qml-probe/CMakeLists.txt),
# then logs raw and brotli sizes against the spike's measured 26,317,972 B /
# 6,788,136 B and fails if the image has drifted far enough that the budget is
# no longer the one the ADR was accepted with.
#
# WHY A BAND AND NOT AN EXACT NUMBER. The spike's image was linked by the Qt
# online installer's kit (different emsdk, different Qt patch level, and the
# design system linked in, which this probe has not got). Equal numbers would be
# a coincidence, not a pass. What matters is the ORDER: a probe that came out at
# 4 MB would mean Qt Quick was silently not linked, and one at 60 MB would mean
# the budget the ADR was accepted with no longer holds.
{
  lib,
  stdenv,
  brotli,
  cmake,
  ninja,
  logosEmscriptenSetup,
  qtWasm,
}:

let
  # The spike's numbers, in bytes. docs/research/spikes/qt-wasm-in-wkwebview.md
  # in logos-workspace, "Sizes:".
  spikeRawBytes = 26317972;
  spikeBrotliBytes = 6788136;

  # Accept anything from "Qt Quick is really in there" to "the ADR's budget
  # still holds". Both ends are failures of a different kind, which is why both
  # are checked rather than only the upper one.
  minRawBytes = 12000000;
  maxRawBytes = 45000000;
in
stdenv.mkDerivation {
  pname = "logos-qt-wasm-qml-probe";
  version = qtWasm.version;

  src = ./qml-probe;

  nativeBuildInputs = [
    cmake
    ninja
    brotli
  ];

  dontUseCmakeConfigure = true;
  dontWrapQtApps = true;
  dontStrip = true;
  dontFixup = true;

  buildPhase = ''
    runHook preBuild
    ${logosEmscriptenSetup}
    cmake -S . -B build -GNinja ${lib.escapeShellArgs qtWasm.cmakeFlags} \
      -DCMAKE_BUILD_TYPE=Release
    cmake --build build --parallel $NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    for f in logos_qt_wasm_probe.wasm logos_qt_wasm_probe.js logos_qt_wasm_probe.html qtloader.js; do
      [ -f "build/$f" ] || { echo "the wasm link produced no $f" >&2; exit 1; }
    done

    mkdir -p $out/www
    cp build/logos_qt_wasm_probe.wasm build/logos_qt_wasm_probe.js \
       build/logos_qt_wasm_probe.html build/qtloader.js $out/www/

    raw=$(wc -c < $out/www/logos_qt_wasm_probe.wasm)
    brotli -q 11 -c $out/www/logos_qt_wasm_probe.wasm > image.br
    br=$(wc -c < image.br)

    pct() { echo "$1 $2" | awk '{ printf "%.0f", ($1 * 100) / $2 }'; }

    echo "logos-qt-wasm-qml-probe: Qt ${qtWasm.version}, single-threaded wasm"
    echo "  raw    $raw B ($(pct "$raw" ${toString spikeRawBytes})% of the spike's ${toString spikeRawBytes} B)"
    echo "  brotli $br B ($(pct "$br" ${toString spikeBrotliBytes})% of the spike's ${toString spikeBrotliBytes} B)"

    if [ "$raw" -lt ${toString minRawBytes} ]; then
      echo "image is under ${toString minRawBytes} B: Qt Quick cannot be linked in" >&2
      exit 1
    fi
    if [ "$raw" -gt ${toString maxRawBytes} ]; then
      echo "image is over ${toString maxRawBytes} B: ADR 0004's per-runtime budget no longer holds" >&2
      exit 1
    fi

    # The measurement, as data, so the Web container's loader page and a CI
    # trend can read it instead of re-weighing the image.
    cat > $out/wasm-size.json <<EOF
    {
      "qt_version": "${qtWasm.version}",
      "emscripten_version": "${qtWasm.prefix.emscriptenVersion}",
      "threads": false,
      "raw_bytes": $raw,
      "brotli_bytes": $br,
      "spike_raw_bytes": ${toString spikeRawBytes},
      "spike_brotli_bytes": ${toString spikeBrotliBytes}
    }
    EOF

    runHook postInstall
  '';

  meta = {
    description = "Qt ${qtWasm.version} for WebAssembly, linked into a Qt Quick image and weighed";
    platforms = lib.platforms.unix;
  };
}
