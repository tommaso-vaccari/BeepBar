#!/bin/bash
set -euo pipefail

original_args=("$@")
version=9.0.2
sha256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
archive="${BEEPBAR_FFMPEG_SOURCE_ARCHIVE:-}"
output=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive) [[ $# -ge 2 ]] || { echo "Missing archive path" >&2; exit 2; }; archive=$2; shift 2 ;;
        --output) [[ $# -ge 2 ]] || { echo "Missing output directory" >&2; exit 2; }; output=$2; shift 2 ;;
        *) echo "Usage: $0 --output DIR [--archive ffmpeg-9.0.2.tar.xz]" >&2; exit 2 ;;
    esac
done
[[ -n "$output" ]] || { echo "An output directory is required" >&2; exit 2; }
[[ "$output" == /* ]] || output="$PWD/$output"

script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
# Compiling FFmpeg takes minutes and the pre-push gate runs this on every push,
# so a finished build is cached. The key is this script's own hash: the version,
# source SHA-256 and configure flags all live here, so any edit that could change
# the binary invalidates the entry. The compiler and SDK are in the key too: the
# same script built with another clang or macOS SDK is another binary. Entries are built in a temp dir inside the
# cache root and moved into place, so an interrupted or concurrent run never
# leaves a partial entry that a later run would treat as a hit.
outputs=(ffmpeg COPYING.LGPLv2.1 ffmpeg-source.tar.gz)
cache_root="${BEEPBAR_FFMPEG_CACHE:-$HOME/Library/Caches/BeepBar-build/ffmpeg}"
cache_key="$({ cat "$script_path"; xcrun clang --version; xcrun --show-sdk-version; } | shasum -a 256 | awk '{print $1}')"
cache_entry="$cache_root/$cache_key"
mkdir -p "$cache_root"
# flock is released even after a crash. Keep the descriptor across exec so the
# lock covers validation, repair, publication and copying to the caller.
if [[ "${BEEPBAR_FFMPEG_LOCKED:-}" != "$cache_key" ]]; then
    exec python3 -c '
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
os.set_inheritable(fd, True)
os.environ["BEEPBAR_FFMPEG_LOCKED"] = sys.argv[2]
os.execv("/bin/bash", ["/bin/bash", sys.argv[3], *sys.argv[4:]])
' "$cache_root/.lock-$cache_key" "$cache_key" "$script_path" "${original_args[@]}"
fi
cache_is_valid() {
    local f
    for f in "${outputs[@]}"; do [[ -s "$1/$f" ]] || return 1; done
    [[ -x "$1/ffmpeg" && -s "$1/SHA256SUMS" ]] || return 1
    (cd "$1" && [[ "$(shasum -a 256 "${outputs[@]}")" == "$(cat SHA256SUMS)" ]])
}
copy_outputs() {
    local f
    mkdir -p "$2"
    for f in "${outputs[@]}"; do cp "$1/$f" "$2/$f"; done
}
if cache_is_valid "$cache_entry"; then
    echo "Using cached FFmpeg build $cache_key"
    copy_outputs "$cache_entry" "$output"
    exit 0
fi

work="$(mktemp -d "$cache_root/.build.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
source_archive="$work/ffmpeg-$version.tar.xz"
if [[ -n "$archive" ]]; then
    cp "$archive" "$source_archive"
else
    curl --fail --location --silent --show-error "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz" --output "$source_archive"
fi
actual_sha256="$(shasum -a 256 "$source_archive" | awk '{print $1}')"
[[ "$actual_sha256" == "$sha256" ]] || { echo "FFmpeg source SHA-256 mismatch" >&2; exit 1; }

tar -xJf "$source_archive" -C "$work"
cd "$work/ffmpeg-$version"
./configure \
    --arch=arm64 --cc=clang --disable-everything --disable-autodetect \
    --disable-doc --disable-debug --disable-ffplay --disable-ffprobe \
    --disable-avdevice --disable-network --disable-swscale --enable-ffmpeg \
    --enable-protocol=file,concat --enable-demuxer=mov,pcm_f32le \
    --enable-decoder=aac,pcm_f32le --enable-encoder=aac,pcm_f32le \
    --enable-muxer=framecrc,wav,mpegts \
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb \
    --enable-parser=aac,h264,hevc \
    --enable-filter=aresample,atrim,aformat,asetpts,highpass,lowpass,afftdn,equalizer,dynaudnorm,agate,volume,alimiter,acompressor \
    --extra-cflags=-mmacosx-version-min=14.0 --extra-ldflags=-mmacosx-version-min=14.0
make -j"$(sysctl -n hw.ncpu)" ffmpeg
strip -x ffmpeg

mkdir -p "$work/source" "$work/out"
cp "$source_archive" "$work/source/ffmpeg-$version.tar.xz"
cp "$script_path" "$work/source/build-ffmpeg.sh"
tar -czf "$work/ffmpeg-source.tar.gz" -C "$work/source" .
cp ffmpeg "$work/out/ffmpeg"
cp COPYING.LGPLv2.1 "$work/out/COPYING.LGPLv2.1"
cp "$work/ffmpeg-source.tar.gz" "$work/out/ffmpeg-source.tar.gz"
(cd "$work/out" && shasum -a 256 "${outputs[@]}" > SHA256SUMS)

# The lock makes replacement safe, while the rename prevents partial entries.
rm -rf "$cache_entry"
mv "$work/out" "$cache_entry"
copy_outputs "$cache_entry" "$output"
