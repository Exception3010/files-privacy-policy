#!/usr/bin/env bash
#
# Builds the FFmpeg audio decoders for the media3 FFmpeg extension, inside WSL (Ubuntu), and
# copies the result into this module's jni/ffmpeg directory on the Windows side.
#
# What it does, in order:
#   1. downloads the Linux Android NDK r26b (the version media3's README says the build was
#      tested with) into ~/ffmpeg-build;
#   2. clones FFmpeg's release/6.0 branch (the version media3 1.9.0 recommends);
#   3. runs media3's own build_ffmpeg.sh (from androidx/media tag 1.9.0, Apache-2.0) with three
#      flags added so configure refuses anything that is not LGPL v2.1: --disable-gpl,
#      --disable-nonfree, --disable-version3;
#   4. checks that every requested decoder is really in the libraries;
#   5. writes BUILD-INFO.txt (source commit, options, decoders) and copies the static libraries,
#      the public headers, the licence files and BUILD-INFO.txt to jni/ffmpeg.
#
# Every decoder in DECODERS is one of FFmpeg's own, LGPL-licensed decoders; none needs an
# external library. The result is static libraries that media3's CMakeLists.txt links into
# libffmpegJNI.so, which the app loads with System.loadLibrary.
#
# Run from Windows (Git Bash or PowerShell):
#   wsl.exe -d Ubuntu -- bash -lc "bash /mnt/c/Users/Abo_Salah/StudioProjects/FileManager/media3-ffmpeg/build-ffmpeg-wsl.sh"
# Needs in WSL: bash, curl, git, make, python3 (to unpack the NDK), a C compiler for
# configure's host checks. Downloads about 700 MB for the NDK and builds in ~/ffmpeg-build.
set -euo pipefail

ROOT="${FFMPEG_BUILD_ROOT:-$HOME/ffmpeg-build}"
NDK_VER="r26b"
NDK_ZIP="android-ndk-${NDK_VER}-linux.zip"
NDK_URL="https://dl.google.com/android/repository/${NDK_ZIP}"
FFMPEG_REPO="https://github.com/FFmpeg/FFmpeg.git"
FFMPEG_BRANCH="release/6.0"
HOST_PLATFORM="linux-x86_64"
# The lowest API level the app runs on (minSdk); must not exceed it.
ANDROID_ABI=26

# Where the module lives on the Windows side, as WSL sees it.
MODULE_DIR="${FFMPEG_MODULE_DIR:-/mnt/c/Users/Abo_Salah/StudioProjects/FileManager/media3-ffmpeg}"
JNI_SRC="$MODULE_DIR/src/main/jni"
DEST="$JNI_SRC/ffmpeg"

# FFmpeg's own decoders, all LGPL, and exactly the ones media3 1.9.0 can ask for: its
# FfmpegLibrary.getCodecName maps a track's MIME type to one of these names and nothing else, so
# a decoder outside this list (WMA, Monkey's Audio, WavPack, RealAudio, MLP) would be compiled
# in and never used. The platform already decodes aac, mp3, vorbis, opus, flac, amr and pcm on
# every phone; they are kept because a few devices' decoders refuse odd streams and the fallback
# then has somewhere to go. The gaps this closes are the Dolby and DTS sound tracks of films:
# ac3, eac3, truehd, dca. MPEG layers I and II go to the mp3 decoder, which handles all three.
DECODERS=(vorbis opus flac alac pcm_mulaw pcm_alaw mp3 amrnb amrwb aac ac3 eac3 dca truehd)

mkdir -p "$ROOT"
LOG="$ROOT/build.log"
exec > >(tee -a "$LOG") 2>&1
echo "== $(date -Is) start, root $ROOT"

for tool in curl git make python3; do
  command -v "$tool" >/dev/null || { echo "missing $tool"; exit 1; }
done
[ -f "$JNI_SRC/build_ffmpeg.sh" ] || { echo "missing $JNI_SRC/build_ffmpeg.sh"; exit 1; }

cd "$ROOT"

# Extracts a zip keeping Unix modes and symlinks, which Python's zipfile drops on its own.
# Used because a stock WSL Ubuntu has python3 but not unzip, and installing needs a password.
extract_zip() {
  python3 - "$1" <<'PY'
import os, stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for info in z.infolist():
        mode = info.external_attr >> 16
        if stat.S_ISLNK(mode):
            target = z.read(info).decode()
            os.makedirs(os.path.dirname(info.filename) or ".", exist_ok=True)
            if os.path.lexists(info.filename):
                os.remove(info.filename)
            os.symlink(target, info.filename)
            continue
        z.extract(info)
        if mode and not info.is_dir():
            os.chmod(info.filename, stat.S_IMODE(mode))
PY
}

# Downloads made on the Windows side are used when they exist: WSL's own network is not always
# there (no DNS from a sandboxed shell, for one). Fetch them with, on Windows:
#   curl -L -o C:\Users\Abo_Salah\ffmpeg-build-dl\android-ndk-r26b-linux.zip <NDK_URL>
#   git -c core.autocrlf=false clone --depth 1 --branch release/6.0 <FFMPEG_REPO> C:\Users\Abo_Salah\ffmpeg-build-dl\ffmpeg
# The clone must keep LF line endings: FFmpeg's configure is a shell script.
WIN_DL="${FFMPEG_WIN_DL:-/mnt/c/Users/Abo_Salah/ffmpeg-build-dl}"

# ---- 1. NDK
NDK_PATH="$ROOT/android-ndk-$NDK_VER"
if [ ! -d "$NDK_PATH" ]; then
  if [ -f "$ROOT/$NDK_ZIP" ]; then
    extract_zip "$ROOT/$NDK_ZIP"
  elif [ -f "$WIN_DL/$NDK_ZIP" ]; then
    extract_zip "$WIN_DL/$NDK_ZIP"
  else
    curl -fL --retry 3 -o "$NDK_ZIP" "$NDK_URL"
    extract_zip "$NDK_ZIP"
  fi
fi
[ -d "$NDK_PATH/toolchains/llvm/prebuilt/$HOST_PLATFORM/bin" ] || { echo "NDK layout unexpected"; exit 1; }

# ---- 2. FFmpeg
if [ ! -d "$ROOT/ffmpeg/.git" ]; then
  if [ -d "$WIN_DL/ffmpeg/.git" ]; then
    # Copied into the Linux file system: a build on /mnt/c is many times slower.
    cp -r "$WIN_DL/ffmpeg" "$ROOT/ffmpeg"
    chmod +x "$ROOT/ffmpeg/configure" "$ROOT/ffmpeg/ffbuild/"*.sh 2>/dev/null || true
    grep -q $'\r' "$ROOT/ffmpeg/configure" && { echo "configure has CRLF line endings; reclone with core.autocrlf=false"; exit 1; }
  else
    git clone --depth 1 --branch "$FFMPEG_BRANCH" "$FFMPEG_REPO" "$ROOT/ffmpeg"
  fi
fi
FFMPEG_COMMIT="$(git -C "$ROOT/ffmpeg" rev-parse HEAD)"
FFMPEG_DATE="$(git -C "$ROOT/ffmpeg" log -1 --format=%ad --date=short)"
FFMPEG_RELEASE="$(cat "$ROOT/ffmpeg/RELEASE")"
echo "FFmpeg $FFMPEG_RELEASE at $FFMPEG_COMMIT ($FFMPEG_DATE)"

# ---- 3. media3's build script, with the licence flags added
WORK="$ROOT/module"
rm -rf "$WORK"
mkdir -p "$WORK/jni"
cp "$JNI_SRC/build_ffmpeg.sh" "$WORK/jni/build_ffmpeg.sh"
chmod +x "$WORK/jni/build_ffmpeg.sh"
# A checkout made by Git for Windows can carry CRLF line endings, which break both bash and
# the pattern below; the copy is made LF whatever the original was.
sed -i 's/\r$//' "$WORK/jni/build_ffmpeg.sh"
sed -i 's/^    --target-os=android$/    --target-os=android\n    --disable-gpl\n    --disable-nonfree\n    --disable-version3/' "$WORK/jni/build_ffmpeg.sh"
grep -q -- '--disable-version3' "$WORK/jni/build_ffmpeg.sh" || { echo "licence flags not inserted"; exit 1; }
ln -sfn "$ROOT/ffmpeg" "$WORK/jni/ffmpeg"

# A finished build is kept when it was made from the same inputs, so the check, the build
# details and the copy below can be redone on their own; a changed decoder list, NDK, API level
# or flag set rebuilds, as does FFMPEG_REBUILD=1. The stamp also dates the build details.
STAMP="$ROOT/ffmpeg/android-libs/.inputs"
INPUTS="ndk=$NDK_VER api=$ANDROID_ABI commit=$FFMPEG_COMMIT flags=--disable-gpl,--disable-nonfree,--disable-version3 decoders=${DECODERS[*]}"
built=1
for abi in armeabi-v7a arm64-v8a x86 x86_64; do
  [ -f "$ROOT/ffmpeg/android-libs/$abi/libavcodec.a" ] || built=0
done
[ -f "$STAMP" ] && [ "$(sed -n 1p "$STAMP")" = "$INPUTS" ] || built=0
if [ "$built" = 1 ] && [ -z "${FFMPEG_REBUILD:-}" ]; then
  echo "libraries already built from these inputs; set FFMPEG_REBUILD=1 to build again"
else
  rm -rf "$ROOT/ffmpeg/android-libs"
  ( cd "$WORK/jni" && ./build_ffmpeg.sh "$WORK" "$NDK_PATH" "$HOST_PLATFORM" "$ANDROID_ABI" "${DECODERS[@]}" )
  printf '%s\n%s\n' "$INPUTS" "$(date -u +%Y-%m-%d)" > "$STAMP"
fi
BUILT_ON="$(sed -n 2p "$STAMP")"

# ---- 4. check the decoders are in
NM="$NDK_PATH/toolchains/llvm/prebuilt/$HOST_PLATFORM/bin/llvm-nm"
CHECK=""
for abi in armeabi-v7a arm64-v8a x86 x86_64; do
  lib="$ROOT/ffmpeg/android-libs/$abi/libavcodec.a"
  [ -f "$lib" ] || { echo "missing $lib"; exit 1; }
  # nm is read once into a variable: piped straight into grep -q it would be cut off by the
  # first match, and under pipefail that reads as a failure.
  symbols="$("$NM" "$lib" 2>/dev/null)"
  missing=""
  for d in "${DECODERS[@]}"; do
    grep -q " ff_${d}_decoder$" <<<"$symbols" || missing="$missing $d"
  done
  if [ -n "$missing" ]; then echo "$abi lacks:$missing"; exit 1; fi
  # And nothing beyond the list: the decoders FFmpeg registered are the ones allcodecs.o refers
  # to, so a stale library with more in it than DECODERS says is caught too.
  registered="$(awk '/^allcodecs\.o:/{f=1;next} /^[^ ]+\.o:$/{f=0} f && / U ff_[a-z0-9_]+_decoder$/{sub(/^ff_/,"",$NF); sub(/_decoder$/,"",$NF); print $NF}' <<<"$symbols" | sort | tr '\n' ' ')"
  wanted="$(printf '%s\n' "${DECODERS[@]}" | sort | tr '\n' ' ')"
  if [ "$registered" != "$wanted" ]; then echo "$abi registers [$registered] but DECODERS is [$wanted]"; exit 1; fi
  CHECK="$CHECK$abi: all ${#DECODERS[@]} decoders present, libavcodec.a $(du -k "$lib" | cut -f1) KB\n"
done
printf "%b" "$CHECK"

# ---- 5. dist
LICENSE_LINE="$(grep '^License:' "$LOG" | tail -1 || true)"
DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"
cp -r "$ROOT/ffmpeg/android-libs" "$DIST/"
for lib in libavcodec libavutil libswresample; do
  mkdir -p "$DIST/$lib"
  cp "$ROOT/ffmpeg/$lib/"*.h "$DIST/$lib/"
done
cp "$ROOT/ffmpeg/COPYING.LGPLv2.1" "$ROOT/ffmpeg/LICENSE.md" "$DIST/"

{
  echo "FFmpeg build details"
  echo
  echo "FFmpeg version: $FFMPEG_RELEASE (branch $FFMPEG_BRANCH)"
  echo "Source commit: $FFMPEG_COMMIT ($FFMPEG_DATE)"
  echo "Source: https://github.com/FFmpeg/FFmpeg/tree/$FFMPEG_COMMIT"
  echo "        mirror of https://git.ffmpeg.org/ffmpeg.git"
  echo "Modifications to FFmpeg: none"
  echo "Built: $BUILT_ON with Android NDK $NDK_VER ($HOST_PLATFORM), minimum API $ANDROID_ABI"
  echo "configure reported: ${LICENSE_LINE:-see build.log}"
  echo
  echo "Enabled decoders: ${DECODERS[*]}"
  echo
  echo "configure options common to every ABI:"
  sed -n '/^COMMON_OPTIONS="/,/^    "/p' "$WORK/jni/build_ffmpeg.sh" | sed '1d;$d' | sed 's/^ */  /'
  echo "  --enable-decoder=<each decoder above>"
  echo
  echo "Per ABI: armeabi-v7a --arch=arm --cpu=armv7-a --extra-cflags=\"-march=armv7-a -mfloat-abi=softfp\" --extra-ldflags=\"-Wl,--fix-cortex-a8\";"
  echo "  arm64-v8a --arch=aarch64 --cpu=armv8-a; x86 --arch=x86 --cpu=i686 --disable-asm; x86_64 --arch=x86_64 --cpu=x86-64 --disable-asm."
  echo
  echo "Build script: build_ffmpeg.sh from androidx/media tag 1.9.0, libraries/decoder_ffmpeg/src/main/jni,"
  echo "  with --disable-gpl --disable-nonfree --disable-version3 added by build-ffmpeg-wsl.sh, which is"
  echo "  published with this file at https://exception3010.github.io/files-privacy-policy/third-party.html"
  echo "Linked into libffmpegJNI.so by CMakeLists.txt and ffmpeg_jni.cc from the same tag (Apache License 2.0)."
  echo
  printf "%b" "$CHECK"
} > "$DIST/BUILD-INFO.txt"
cat "$DIST/BUILD-INFO.txt"

# ---- copy to the module
rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$DIST/." "$DEST/"
echo "== $(date -Is) done: $DEST"
