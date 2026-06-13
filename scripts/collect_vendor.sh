#!/bin/bash
set -eo pipefail

# Collect all Homebrew dylib dependencies for libmpv and embed them
# in vendor/lib with @rpath install names. Run once, then commit vendor/.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_LIB="$PROJECT_DIR/vendor/lib"
VENDOR_INCLUDE="$PROJECT_DIR/vendor/include"
HOMEBREW_PREFIX="/opt/homebrew"
TMPDIR_WORK=$(mktemp -d)
QUEUE_FILE="$TMPDIR_WORK/queue"
VISITED_FILE="$TMPDIR_WORK/visited"

touch "$QUEUE_FILE" "$VISITED_FILE"
trap "rm -rf $TMPDIR_WORK" EXIT

SEED_LIBS=(
    "$HOMEBREW_PREFIX/lib/libmpv.dylib"
    "$HOMEBREW_PREFIX/lib/libavformat.dylib"
    "$HOMEBREW_PREFIX/lib/libavcodec.dylib"
    "$HOMEBREW_PREFIX/lib/libswscale.dylib"
    "$HOMEBREW_PREFIX/lib/libswresample.dylib"
    "$HOMEBREW_PREFIX/lib/libavutil.dylib"
)

echo "==> Cleaning vendor directories..."
rm -rf "$VENDOR_LIB" "$VENDOR_INCLUDE"
mkdir -p "$VENDOR_LIB" "$VENDOR_INCLUDE/mpv"

is_visited() { grep -qxF "$1" "$VISITED_FILE" 2>/dev/null; }

# --- BFS to collect all Homebrew dylib deps ---

for seed in "${SEED_LIBS[@]}"; do
    real=$(realpath "$seed")
    if ! is_visited "$real"; then
        echo "$real" >> "$VISITED_FILE"
        echo "$real" >> "$QUEUE_FILE"
    fi
done

i=0
total=$(wc -l < "$QUEUE_FILE")
while [ "$i" -lt "$total" ]; do
    i=$((i + 1))
    lib=$(sed -n "${i}p" "$QUEUE_FILE")
    [ -z "$lib" ] && continue

    deps=$(otool -L "$lib" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep "^$HOMEBREW_PREFIX/" || true)
    for dep in $deps; do
        dep_real=$(realpath "$dep" 2>/dev/null || echo "")
        [ -z "$dep_real" ] && continue
        if ! is_visited "$dep_real"; then
            echo "$dep_real" >> "$VISITED_FILE"
            echo "$dep_real" >> "$QUEUE_FILE"
            total=$((total + 1))
        fi
    done
done

DYLIB_COUNT=$(wc -l < "$QUEUE_FILE" | tr -d ' ')
echo "==> Found $DYLIB_COUNT Homebrew dylibs"

# --- Copy dylibs ---

while IFS= read -r lib; do
    bn=$(basename "$lib")
    cp "$lib" "$VENDOR_LIB/$bn"
    chmod u+w "$VENDOR_LIB/$bn"
done < "$QUEUE_FILE"

echo "==> Rewriting install names..."

# --- Fix install names ---
# Strategy: for any /opt/homebrew/... reference, resolve via realpath to get
# the actual filename we copied. This handles opt/ symlinks, Cellar/ paths, etc.

resolve_to_vendor_name() {
    local ref="$1"
    # Try realpath to resolve symlinks
    local real
    real=$(realpath "$ref" 2>/dev/null || echo "")
    if [ -n "$real" ]; then
        local bn
        bn=$(basename "$real")
        if [ -f "$VENDOR_LIB/$bn" ]; then
            echo "$bn"
            return
        fi
    fi
    # Fallback: just use basename of the reference
    local bn
    bn=$(basename "$ref")
    # Try to find a matching file (e.g., libfoo.3.dylib might match libfoo.3.5.2.dylib)
    local match
    match=$(ls "$VENDOR_LIB"/${bn%.dylib}*.dylib 2>/dev/null | head -1)
    if [ -n "$match" ]; then
        basename "$match"
        return
    fi
    echo ""
}

for dylib in "$VENDOR_LIB"/*.dylib; do
    bn=$(basename "$dylib")

    # Set identity
    install_name_tool -id "@rpath/$bn" "$dylib" 2>/dev/null || true

    # Rewrite all homebrew references
    deps=$(otool -L "$dylib" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep "^$HOMEBREW_PREFIX/" || true)
    for dep in $deps; do
        target=$(resolve_to_vendor_name "$dep")
        if [ -n "$target" ]; then
            install_name_tool -change "$dep" "@rpath/$target" "$dylib" 2>/dev/null || true
        else
            echo "    WARNING: Cannot resolve $dep for $bn"
        fi
    done

    # Ad-hoc codesign
    codesign --force --sign - --timestamp=none "$dylib" 2>/dev/null || true
done

# --- Create unversioned symlinks for linker (-lmpv finds libmpv.dylib) ---

echo "==> Creating linker symlinks..."
for dylib in "$VENDOR_LIB"/*.dylib; do
    bn=$(basename "$dylib")
    # Extract lib name: libfoo.X.Y.Z.dylib -> libfoo
    libname=$(echo "$bn" | sed -E 's/^(lib[a-zA-Z0-9_+-]+)\..*/\1/')
    link="$VENDOR_LIB/${libname}.dylib"
    if [ ! -e "$link" ] && [ "$link" != "$dylib" ]; then
        ln -s "$bn" "$link"
    fi
done

# --- Copy mpv headers ---

echo "==> Copying mpv headers..."
for header in client.h render.h render_gl.h stream_cb.h; do
    src="$HOMEBREW_PREFIX/include/mpv/$header"
    if [ -f "$src" ]; then
        cp "$src" "$VENDOR_INCLUDE/mpv/$header"
    fi
done

# --- Summary ---

echo ""
echo "==> Done!"
echo "    Dylibs:  $(ls "$VENDOR_LIB"/*.dylib 2>/dev/null | wc -l | tr -d ' ') files in vendor/lib/"
echo "    Headers: $(ls "$VENDOR_INCLUDE/mpv/"*.h 2>/dev/null | wc -l | tr -d ' ') files in vendor/include/mpv/"
echo ""
echo "    Total size: $(du -sh "$VENDOR_LIB" | awk '{print $1}')"
echo ""

# Verify no homebrew paths remain
echo "==> Verifying no /opt/homebrew paths remain..."
bad=0
for dylib in "$VENDOR_LIB"/*.dylib; do
    refs=$(otool -L "$dylib" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep "^$HOMEBREW_PREFIX/" || true)
    if [ -n "$refs" ]; then
        echo "    WARNING: $(basename "$dylib") still references:"
        echo "$refs" | sed 's/^/      /'
        bad=1
    fi
done

if [ "$bad" -eq 0 ]; then
    echo "    All clean! No /opt/homebrew references found."
else
    echo ""
    echo "    Some dylibs still have unresolved homebrew references."
fi
