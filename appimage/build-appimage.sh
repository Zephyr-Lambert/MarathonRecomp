#!/usr/bin/env bash
# Repackages the official Marathon Recompiled Flatpak bundle as an AppImage.
# Usage: build-appimage.sh <path to .flatpak bundle> <output .AppImage path>
set -euo pipefail

BUNDLE="$(readlink -f "$1")"
OUTPUT="$(readlink -m "$2")"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
APP_ID=io.github.sonicnext_dev.marathonrecomp
ARCH=x86_64
FP_ROOT="$HOME/.local/share/flatpak"

echo "::group::Install Flatpak bundle and its runtime"
flatpak --user remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak --user install -y --noninteractive --no-related "$BUNDLE"
echo "::endgroup::"

APP_FILES="$FP_ROOT/app/$APP_ID/$ARCH/master/active/files"
if [ ! -d "$APP_FILES" ]; then
    APP_FILES="$(echo "$FP_ROOT"/app/"$APP_ID"/"$ARCH"/*/active/files | awk '{print $1}')"
fi
APP_METADATA="$APP_FILES/../metadata"
RUNTIME_REF="$(sed -n 's/^runtime=//p' "$APP_METADATA" | head -n1)"   # e.g. org.freedesktop.Platform/x86_64/25.08
RT_FILES="$FP_ROOT/runtime/$RUNTIME_REF/active/files"
echo "App files:     $APP_FILES"
echo "Runtime:       $RUNTIME_REF"
echo "Runtime files: $RT_FILES"
[ -x "$APP_FILES/bin/MarathonRecomp" ] || { echo "MarathonRecomp binary not found in the Flatpak"; exit 1; }
[ -d "$RT_FILES" ] || { echo "Runtime files not found"; exit 1; }

APPDIR="$(mktemp -d)/AppDir"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib/stdcxx-fallback"
cp -a "$APP_FILES/bin/." "$APPDIR/usr/bin/"
if [ -d "$APP_FILES/lib" ]; then cp -a "$APP_FILES/lib/." "$APPDIR/usr/lib/"; fi

# --- Collect shared libraries from the Flatpak runtime ---------------------------
RT_LIBDIR="$RT_FILES/lib/$ARCH-linux-gnu"
LOADER="$RT_LIBDIR/ld-linux-x86-64.so.2"
SEARCH_PATH="$APP_FILES/lib:$RT_LIBDIR:$RT_FILES/lib"

# Libraries that must come from the host: the C library, graphics drivers and
# display/audio/desktop stacks (bundling these breaks GPUs or desktop integration).
EXCLUDE='^(ld-linux|libc\.|libm\.|libmvec|libdl\.|libpthread|librt\.|libresolv|libutil|libnsl|libanl|libBrokenLocale|libGL|libGLX|libEGL|libGLdispatch|libOpenGL|libGLES|libvulkan|libdrm|libgbm|libX|libxcb|libxkbcommon|libwayland|libdecor|libgtk|libgdk|libglib|libgobject|libgio|libgmodule|libgthread|libpango|libcairo|libharfbuzz|libfontconfig|libfreetype|libatk|libatspi|libepoxy|libdbus|libasound|libpulse|libpipewire|libjack|libudev|libsystemd|libselinux|libmount|libblkid|libffi|libpcre2|libz\.|libexpat|libuuid)'

echo "::group::Full library tree (for reference)"
"$LOADER" --library-path "$SEARCH_PATH" --list "$APPDIR/usr/bin/MarathonRecomp" || true
echo "::endgroup::"

find_lib() {
    local IFS=:
    for d in $SEARCH_PATH; do
        if [ -e "$d/$1" ]; then echo "$d/$1"; return 0; fi
    done
    return 1
}
needed() { objdump -p "$1" | awk '/NEEDED/ { print $2 }'; }

# Walk the dependency tree, but don't descend into host libraries:
# their own dependencies are provided by the host as well.
declare -A SEEN=()
QUEUE=($(needed "$APPDIR/usr/bin/MarathonRecomp"))
while [ ${#QUEUE[@]} -gt 0 ]; do
    NAME="${QUEUE[0]}"; QUEUE=("${QUEUE[@]:1}")
    [ -n "${SEEN[$NAME]:-}" ] && continue
    SEEN[$NAME]=1
    if [[ "$NAME" =~ ^(libstdc\+\+|libgcc_s) ]]; then
        cp -L "$(find_lib "$NAME")" "$APPDIR/usr/lib/stdcxx-fallback/$NAME"
        echo "fallback: $NAME"
    elif [[ "$NAME" =~ $EXCLUDE ]]; then
        echo "host:     $NAME"
    else
        SRC="$(find_lib "$NAME")" || { echo "Cannot find $NAME"; exit 1; }
        cp -L "$SRC" "$APPDIR/usr/lib/$NAME"
        echo "bundled:  $NAME"
        QUEUE+=($(needed "$SRC"))
    fi
done

# Highest C++ runtime version needed, checked by AppRun against the host's copy.
REQ_STDCXX="$(for f in "$APPDIR/usr/bin/MarathonRecomp" "$APPDIR"/usr/lib/*.so*; do
    [ -f "$f" ] && objdump -T "$f" 2>/dev/null | grep -o 'GLIBCXX_[0-9.]*'
done | sort -Vu | tail -n1 || true)"
if [ -n "$REQ_STDCXX" ] && ls "$APPDIR/usr/lib/stdcxx-fallback/"libstdc++* >/dev/null 2>&1; then
    echo "$REQ_STDCXX" > "$APPDIR/usr/lib/stdcxx-fallback/required-version"
else
    rm -rf "$APPDIR/usr/lib/stdcxx-fallback"
fi
REQ_GLIBC="$(objdump -T "$APPDIR/usr/bin/MarathonRecomp" "$APPDIR"/usr/lib/*.so* 2>/dev/null | grep -o "GLIBC_[0-9.]*" | sort -Vu | tail -n1 || true)"
echo "Requires host glibc: $REQ_GLIBC   C++ runtime: ${REQ_STDCXX:-none}"

# --- AppImage metadata -------------------------------------------------------------
install -m755 "$SCRIPT_DIR/AppRun" "$APPDIR/AppRun"
ICON_SRC="$(find "$APP_FILES/share/icons" -name "$APP_ID.png" | sort | tail -n1)"
cp "$ICON_SRC" "$APPDIR/$APP_ID.png"
ln -s "$APP_ID.png" "$APPDIR/.DirIcon"
sed -e 's|^Exec=.*|Exec=MarathonRecomp|' \
    "$APP_FILES/share/applications/$APP_ID.desktop" > "$APPDIR/$APP_ID.desktop"

# --- Build -------------------------------------------------------------------------
TOOL="$(mktemp -d)/appimagetool"
curl -fsSL -o "$TOOL" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
chmod +x "$TOOL"
mkdir -p "$(dirname "$OUTPUT")"
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$TOOL" --no-appstream "$APPDIR" "$OUTPUT"
echo "Built $OUTPUT"
