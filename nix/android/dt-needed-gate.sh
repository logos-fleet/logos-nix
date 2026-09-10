#!/usr/bin/env bash
# logos-android-dt-needed-gate — the Android "no unbundled system libs" gate.
#
# A shared object shipped inside an app may only name, in DT_NEEDED, either
#   * a library the app itself packages (a sibling .so, or one under an
#     explicitly allowed directory), or
#   * a library Android guarantees at the app's API level (the NDK stub set).
#
# Anything else resolves on the build machine and fails on the phone, and it
# fails at dlopen time with an UnsatisfiedLinkError that names one soname and
# none of the reason. This reads what the linker actually recorded, never what
# the build intended -- the same rule the APK gate in mk-apk.nix applies to a
# whole libs/<abi> directory, factored out so a single artifact (a Bare module,
# say) can be gated the moment it is produced rather than when it is packaged.
#
#   usage: logos-android-dt-needed-gate [--allow-dir <dir>]... [--allow <soname>]...
#                                       <artifact.so>...
#   env:   LOGOS_ANDROID_READELF        llvm-readelf to read with   (required)
#          LOGOS_ANDROID_STUB_LIB_DIR   the NDK stub library dir     (required)
#          LOGOS_ANDROID_API_LEVEL      only used in the message     (optional)
#
# Every artifact's own directory is allowed implicitly: an app that ships a
# module ships whatever sits beside it. `--allow` names a single soname the
# CONTAINER guarantees but that is not in either set -- libc++_shared.so is the
# one that exists today, because Qt's Android platform refuses any other STL,
# so every Logos APK packages it.
#
# Exit 0: every DT_NEEDED resolves on device. Exit 1: the foreign sonames are
# named on stderr. Exit 2: usage error, or no usable allowlist to gate against.
set -uo pipefail

READELF="${LOGOS_ANDROID_READELF:-}"
STUB_DIR="${LOGOS_ANDROID_STUB_LIB_DIR:-}"
API_LEVEL="${LOGOS_ANDROID_API_LEVEL:-unknown}"

allow_dirs=()
allow_sonames=()
artifacts=()
while [ $# -gt 0 ]; do
    case "$1" in
        --allow-dir)
            [ $# -ge 2 ] || { echo "logos-android-dt-needed-gate: --allow-dir needs a directory" >&2; exit 2; }
            allow_dirs+=("$2"); shift 2 ;;
        --allow)
            [ $# -ge 2 ] || { echo "logos-android-dt-needed-gate: --allow needs a soname" >&2; exit 2; }
            allow_sonames+=("$2"); shift 2 ;;
        --) shift; artifacts+=("$@"); break ;;
        -*) echo "logos-android-dt-needed-gate: unknown option: $1" >&2; exit 2 ;;
        *)  artifacts+=("$1"); shift ;;
    esac
done

if [ ${#artifacts[@]} -eq 0 ]; then
    echo "logos-android-dt-needed-gate: usage: [--allow-dir <dir>]... <artifact.so>..." >&2
    exit 2
fi
if [ -z "$READELF" ] || [ -z "$STUB_DIR" ]; then
    echo "logos-android-dt-needed-gate: LOGOS_ANDROID_READELF and" \
         "LOGOS_ANDROID_STUB_LIB_DIR must both be set. The gate does not carry" \
         "its own copy of the NDK on purpose." >&2
    exit 2
fi
for a in "${artifacts[@]}"; do
    [ -f "$a" ] || { echo "logos-android-dt-needed-gate: no such artifact: $a" >&2; exit 2; }
    allow_dirs+=("$(dirname "$a")")
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ── the allowlist ───────────────────────────────────────────────────────────
# An empty stub set would pass everything, so refuse to gate against one.
ls "$STUB_DIR"/*.so 2>/dev/null | xargs -n1 basename | sort -u > "$work/android.txt"
if [ ! -s "$work/android.txt" ]; then
    echo "logos-android-dt-needed-gate: no NDK stub libraries under $STUB_DIR;" \
         "refusing to gate against an empty allowlist." >&2
    exit 2
fi
: > "$work/packaged.txt"
for d in "${allow_dirs[@]}"; do
    [ -d "$d" ] || continue
    ls "$d"/*.so 2>/dev/null | xargs -n1 basename >> "$work/packaged.txt"
done
if [ ${#allow_sonames[@]} -gt 0 ]; then
    printf '%s\n' "${allow_sonames[@]}" >> "$work/packaged.txt"
fi
sort -u "$work/packaged.txt" -o "$work/packaged.txt"
sort -u "$work/packaged.txt" "$work/android.txt" > "$work/allowed.txt"

# ── what the linker recorded ────────────────────────────────────────────────
"$READELF" -d "${artifacts[@]}" \
    | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p' \
    | sort -u > "$work/needed.txt"

foreign=$(comm -23 "$work/needed.txt" "$work/allowed.txt")
if [ -n "$foreign" ]; then
    echo "logos-android-dt-needed-gate: FAIL — these DT_NEEDED sonames are" \
         "neither shipped beside the artifact nor provided by Android at API" \
         "$API_LEVEL:" >&2
    printf '  %s\n' $foreign >&2
    echo "Link them into the artifact (static), or ship them next to it." >&2
    exit 1
fi

echo "logos-android-dt-needed-gate: PASS — $(wc -l < "$work/needed.txt" | tr -d ' ')" \
     "DT_NEEDED soname(s) across ${#artifacts[@]} artifact(s), all resolvable on device"
