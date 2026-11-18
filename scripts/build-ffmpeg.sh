#!/bin/bash
set -euo pipefail

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
work="$(mktemp -d "${TMPDIR:-/tmp}/beepbar-ffmpeg.XXXXXXXX")"
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

mkdir -p "$work/source" "$output"
cp "$source_archive" "$work/source/ffmpeg-$version.tar.xz"
cp "$script_path" "$work/source/build-ffmpeg.sh"
tar -czf "$work/ffmpeg-source.tar.gz" -C "$work/source" .
cp ffmpeg "$output/ffmpeg"
cp COPYING.LGPLv2.1 "$output/COPYING.LGPLv2.1"
cp "$work/ffmpeg-source.tar.gz" "$output/ffmpeg-source.tar.gz"
