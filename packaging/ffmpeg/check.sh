#!/usr/bin/env bash
# Proves an ffmpeg can do what the launcher asks of it: every encoder, device, muxer, demuxer,
# filter and protocol its argument lists use (lib/core/replay_buffer.dart, capture/video_encoders.dart,
# capture/broadcast.dart, capture/remote_play.dart, capture/clip_tools.dart, capture/game_sound.dart,
# capture/wayland_capture.dart, looping_video.dart), then a small real run of the parts that
# need no screen or graphics card. Hardware encoders can only be listed here; they are tried at
# run time on the player's computer (VideoEncoder.candidates).
#
#     check.sh <ffmpeg executable> <windows|linux>
set -euo pipefail

ffmpeg="$1"
system="$2"
# ffmpeg.exe gets Windows paths from Git Bash: no rewriting of arguments.
export MSYS2_ARG_CONV_EXCL='*'

"$ffmpeg" -hide_banner -version

failed=0
miss() {
  echo "::error::ffmpeg lacks $1"
  failed=1
}

config="$("$ffmpeg" -hide_banner -version)"
for flag in --enable-gpl --enable-version3 --enable-libx264; do
  grep -q -- "$flag" <<<"$config" || miss "$flag"
done
if grep -q -- '--enable-nonfree' <<<"$config"; then
  echo "::error::a nonfree build must not be published"
  failed=1
fi

# The second column of a listing (name, with commas for several names), without the header.
listing() {
  "$ffmpeg" -hide_banner "$1" 2>/dev/null | tr -d '\r' | awk 'NF >= 2 && $1 !~ /^-+$/ { print $2 }' | tr ',' '\n'
}

require() {
  local flag="$1"
  shift
  local have
  have="$(listing "$flag" | sort -u)"
  echo "== $flag"
  for name in "$@"; do
    if grep -qx -- "$name" <<<"$have"; then
      echo "ok   $name"
    else
      miss "$name in $flag"
    fi
  done
}

case "$system" in
  windows)
    encoders=(libx264 aac mjpeg rawvideo h264_nvenc h264_qsv h264_amf h264_mf)
    devices=(gdigrab dshow lavfi)
    ;;
  linux)
    encoders=(libx264 aac mjpeg rawvideo h264_nvenc h264_vaapi h264_qsv)
    devices=(x11grab pulse lavfi)
    ;;
  *)
    echo "usage: check.sh <ffmpeg> <windows|linux>" >&2
    exit 2
    ;;
esac

require -encoders "${encoders[@]}"
require -devices "${devices[@]}"
require -muxers flv segment mpegts mp4 image2pipe rawvideo null
require -demuxers concat mpegts s16le rawvideo mov
require -filters scale crop pad fps format hwupload aresample aformat amix volume color anullsrc null anull
# -protocols lists names in one column under Input: and Output:.
echo "== -protocols"
protocols="$("$ffmpeg" -hide_banner -protocols 2>/dev/null | tr -d '\r' | awk '{ print $1 }')"
for protocol in rtmp rtmps file pipe; do
  if grep -qx "$protocol" <<<"$protocols"; then echo "ok   $protocol"; else miss "$protocol in -protocols"; fi
done

work="$(mktemp -d)"
command -v cygpath >/dev/null && work="$(cygpath -m "$work")"
quiet=(-hide_banner -loglevel error -nostdin -y)

# What the replay buffer records (x264 and MPEG-TS segments) and how it joins them.
"$ffmpeg" "${quiet[@]}" -f lavfi -i color=c=black:s=320x180:r=30 -frames:v 120 -vf format=yuv420p \
  -c:v libx264 -preset ultrafast -tune zerolatency -crf 28 -pix_fmt yuv420p \
  -force_key_frames 'expr:gte(t,n_forced*2)' -f segment -segment_time 2 -segment_wrap 9 \
  -segment_format mpegts -reset_timestamps 1 "$work/segment%03d.ts"
printf "file 'segment000.ts'\nfile 'segment001.ts'\n" >"$work/join.txt"
"$ffmpeg" "${quiet[@]}" -f concat -safe 0 -i "$work/join.txt" -c copy "$work/clip.mp4"
[ -s "$work/clip.mp4" ] || miss 'a clip from joined segments'

# The clip tools: a poster and a smaller copy.
"$ffmpeg" "${quiet[@]}" -ss 0.5 -i "$work/clip.mp4" -frames:v 1 -vf 'scale=min(1280\,iw):-2' \
  -f image2pipe -c:v mjpeg -q:v 4 "$work/poster.jpg"
[ -s "$work/poster.jpg" ] || miss 'a poster from a clip'
"$ffmpeg" "${quiet[@]}" -i "$work/clip.mp4" -c:v libx264 -preset veryfast -b:v 500000 -maxrate 500000 -bufsize 1000000 \
  -vf 'scale=min(1280\,iw):-2' -pix_fmt yuv420p -movflags +faststart "$work/small.mp4"
[ -s "$work/small.mp4" ] || miss 'a smaller copy of a clip'

# What a video background decodes to.
"$ffmpeg" "${quiet[@]}" -i "$work/clip.mp4" -an -sn -frames:v 3 \
  -vf 'scale=64:36:force_original_aspect_ratio=increase,crop=64:36,fps=30' -pix_fmt rgba -f rawvideo "$work/frames.raw"
[ -s "$work/frames.raw" ] || miss 'raw frames for a video background'

# What Go Live writes, on a file instead of a server.
"$ffmpeg" "${quiet[@]}" -f lavfi -i color=c=black:s=320x180:r=30 -f lavfi -t 1 -i anullsrc=r=48000:cl=stereo -frames:v 30 \
  -vf 'scale=320:180:force_original_aspect_ratio=decrease:flags=bicubic,pad=320:180:(ow-iw)/2:(oh-ih)/2,fps=30,format=yuv420p' \
  -c:v libx264 -preset veryfast -g 60 -c:a aac -b:a 160000 -ar 48000 -f flv "$work/live.flv"
[ -s "$work/live.flv" ] || miss 'FLV for a broadcast'

rm -rf "$work"
exit "$failed"
