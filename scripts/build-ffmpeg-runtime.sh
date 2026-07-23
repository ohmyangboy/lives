#!/bin/bash
set -euo pipefail

source_dir="${1:?Usage: scripts/build-ffmpeg-runtime.sh /path/to/ffmpeg-8.1.2 [output-directory]}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${2:-$project_root/vendor/ffmpeg/macos-arm64}"
build_root="$(mktemp -d /private/tmp/lives-ffmpeg-build.XXXXXX)"
build_dir="$build_root/build"
install_dir="$build_root/install"

cleanup() {
  rm -rf "$build_root"
}
trap cleanup EXIT

mkdir -p "$build_dir" "$install_dir" "$output_dir/bin" "$output_dir/lib"
build_jobs=4
if detected_jobs="$(sysctl -n hw.logicalcpu 2>/dev/null)"; then
  build_jobs="$detected_jobs"
fi

cd "$build_dir"
"$source_dir/configure" \
  --prefix="$install_dir" \
  --install-name-dir=@rpath \
  --arch=arm64 \
  --target-os=darwin \
  --cc=clang \
  --disable-autodetect \
  --disable-static \
  --enable-shared \
  --disable-doc \
  --disable-debug \
  --disable-network \
  --disable-programs \
  --enable-ffmpeg \
  --disable-everything \
  --enable-avcodec \
  --enable-avformat \
  --enable-avfilter \
  --enable-swscale \
  --enable-swresample \
  --enable-protocol=file \
  --enable-demuxer=mov \
  --enable-muxer=mov \
  --enable-decoder=vp8,vp9,av1,opus,vorbis \
  --enable-encoder=prores_ks,aac \
  --enable-parser=vp8,vp9,av1,opus,vorbis \
  --enable-filter=scale,format,aresample \
  --enable-audiotoolbox \
  --extra-cflags=-mmacosx-version-min=13.0 \
  --extra-ldflags="-mmacosx-version-min=13.0 -Wl,-rpath,@executable_path/../lib"

make -j"$build_jobs"
make install

cp "$install_dir/bin/ffmpeg" "$output_dir/bin/ffmpeg"
cp -a "$install_dir/lib/"*.dylib "$output_dir/lib/"
chmod +x "$output_dir/bin/ffmpeg"

echo "FFmpeg runtime written to $output_dir"
