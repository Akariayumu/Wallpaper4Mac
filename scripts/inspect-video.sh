#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/video"
  exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "ffprobe is required. Install ffmpeg first: brew install ffmpeg"
  exit 1
fi

input=$1
if [[ ! -f "$input" ]]; then
  echo "File not found: $input"
  exit 1
fi

video_info=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,profile,pix_fmt,width,height,avg_frame_rate,bit_rate \
  -of default=noprint_wrappers=1:nokey=0 "$input")
format_info=$(ffprobe -v error \
  -show_entries format=format_name,duration,bit_rate \
  -of default=noprint_wrappers=1:nokey=0 "$input")
audio_streams=$(ffprobe -v error -select_streams a \
  -show_entries stream=index -of csv=p=0 "$input" | wc -l | tr -d ' ')

get_field() {
  local key=$1
  local payload=$2
  printf '%s\n' "$payload" | awk -F= -v key="$key" '$1 == key { print $2; exit }'
}

codec=$(get_field codec_name "$video_info")
profile=$(get_field profile "$video_info")
pix_fmt=$(get_field pix_fmt "$video_info")
width=$(get_field width "$video_info")
height=$(get_field height "$video_info")
avg_frame_rate=$(get_field avg_frame_rate "$video_info")
stream_bitrate=$(get_field bit_rate "$video_info")
format_name=$(get_field format_name "$format_info")
duration=$(get_field duration "$format_info")
total_bitrate=$(get_field bit_rate "$format_info")

fps=$(awk -F/ '
  NF == 2 && $2 != 0 { printf "%.2f", $1 / $2; next }
  NF == 1 { printf "%.2f", $1; next }
  { printf "unknown" }
' <<<"$avg_frame_rate")

echo "File: $input"
echo "Container: ${format_name:-unknown}"
echo "Codec: ${codec:-unknown}"
echo "Profile: ${profile:-unknown}"
echo "Pixel format: ${pix_fmt:-unknown}"
echo "Resolution: ${width:-?}x${height:-?}"
echo "Frame rate: ${fps}"
echo "Duration: ${duration:-unknown} seconds"
echo "Video bitrate: ${stream_bitrate:-unknown} bps"
echo "Total bitrate: ${total_bitrate:-unknown} bps"
echo "Audio streams: $audio_streams"
echo
echo "Recommendations:"

if [[ "$codec" != "hevc" ]]; then
  echo "- Convert to HEVC/H.265 for lower decode power on modern Macs."
else
  echo "- Codec is already HEVC, which is the preferred decode path."
fi

if [[ "$audio_streams" != "0" ]]; then
  echo "- Remove audio tracks with -an. The wallpaper app is muted, so audio wastes space and decode work."
else
  echo "- No audio streams detected."
fi

if awk 'BEGIN { exit !('"${fps:-0}"' > 30.0) }'; then
  echo "- Clamp frame rate to 24 or 30 fps unless the motion really needs more."
else
  echo "- Frame rate is already in a wallpaper-friendly range."
fi

if [[ "${height:-0}" -gt 2160 ]]; then
  echo "- Downscale above 4K. Extra pixels raise decode and memory bandwidth for little wallpaper benefit."
elif [[ "${height:-0}" -gt 1440 ]]; then
  echo "- Consider a 1440p or 4K export depending on your display. 1440p is often the best power/quality tradeoff."
else
  echo "- Resolution is already reasonable for a power-efficient wallpaper."
fi

if [[ "$pix_fmt" != "yuv420p" ]]; then
  echo "- Prefer yuv420p for broad hardware decode compatibility."
else
  echo "- Pixel format is already yuv420p."
fi
