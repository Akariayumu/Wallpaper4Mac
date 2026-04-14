#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  transcode-wallpaper.sh INPUT OUTPUT [--profile 1080p|1440p|4k|source] [--fps 24|30] [--codec auto|hevc|h264]

Examples:
  ./scripts/transcode-wallpaper.sh input.mov output-1440p-hevc.mp4
  ./scripts/transcode-wallpaper.sh input.mp4 output-1080p.mp4 --profile 1080p --fps 24
EOF
}

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
  echo "ffmpeg and ffprobe are required. Install them first: brew install ffmpeg"
  exit 1
fi

input=$1
output=$2
shift 2

profile=1440p
fps=30
codec=auto

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile=${2:-}
      shift 2
      ;;
    --fps)
      fps=${2:-}
      shift 2
      ;;
    --codec)
      codec=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "$input" ]]; then
  echo "File not found: $input"
  exit 1
fi

case "$profile" in
  1080p)
    target_width=1920
    target_height=1080
    target_bitrate=3500k
    maxrate=5000k
    bufsize=7000k
    ;;
  1440p)
    target_width=2560
    target_height=1440
    target_bitrate=6000k
    maxrate=8000k
    bufsize=12000k
    ;;
  4k)
    target_width=3840
    target_height=2160
    target_bitrate=10000k
    maxrate=14000k
    bufsize=20000k
    ;;
  source)
    target_width=16384
    target_height=16384
    target_bitrate=8000k
    maxrate=12000k
    bufsize=16000k
    ;;
  *)
    echo "Unsupported profile: $profile"
    exit 1
    ;;
esac

case "$fps" in
  24|30)
    ;;
  *)
    echo "Unsupported fps: $fps"
    exit 1
    ;;
esac

if [[ "$codec" == "auto" || "$codec" == "hevc" ]]; then
  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'hevc_videotoolbox'; then
    codec=hevc_videotoolbox
  else
    codec=libx265
  fi
elif [[ "$codec" == "h264" ]]; then
  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'h264_videotoolbox'; then
    codec=h264_videotoolbox
  else
    codec=libx264
  fi
else
  echo "Unsupported codec: $codec"
  exit 1
fi

scale_filter="scale=w='min(iw,${target_width})':h='min(ih,${target_height})':force_original_aspect_ratio=decrease:force_divisible_by=2"
common_args=(
  -hide_banner
  -y
  -i "$input"
  -map 0:v:0
  -an
  -sn
  -dn
  -map_metadata -1
  -map_chapters -1
  -vf "$scale_filter"
  -r "$fps"
  -pix_fmt yuv420p
  -movflags +faststart
)

echo "Input: $input"
echo "Output: $output"
echo "Profile: $profile"
echo "Frame rate: ${fps} fps"
echo "Encoder: $codec"
echo "Audio: removed"
echo

case "$codec" in
  hevc_videotoolbox)
    ffmpeg "${common_args[@]}" \
      -c:v hevc_videotoolbox \
      -tag:v hvc1 \
      -b:v "$target_bitrate" \
      -maxrate "$maxrate" \
      -bufsize "$bufsize" \
      "$output"
    ;;
  libx265)
    ffmpeg "${common_args[@]}" \
      -c:v libx265 \
      -tag:v hvc1 \
      -preset medium \
      -crf 28 \
      "$output"
    ;;
  h264_videotoolbox)
    ffmpeg "${common_args[@]}" \
      -c:v h264_videotoolbox \
      -b:v "$target_bitrate" \
      -maxrate "$maxrate" \
      -bufsize "$bufsize" \
      "$output"
    ;;
  libx264)
    ffmpeg "${common_args[@]}" \
      -c:v libx264 \
      -preset medium \
      -crf 23 \
      "$output"
    ;;
esac

echo
echo "Done. Inspect the result with:"
echo "  ./scripts/inspect-video.sh \"$output\""
