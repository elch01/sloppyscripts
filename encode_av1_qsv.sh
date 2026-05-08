#!/usr/bin/env bash
# encode_av1_qsv.sh — Batch re-encode to AV1 via Intel QSV
#
# Requirements:
#   - FFmpeg built with oneVPL/QSV support
#   - Intel iHD media driver, verified with vainfo
#   - Ubuntu 26.04 / Linux 7.x (Should reasonably work on earlier or later releases)
#
# Usage:
#   ./encode_av1_qsv.sh [OPTIONS] [INPUT_DIR]
#
# Options:
#   --debug, -d        Verbose output, system diagnostics, smoke-test, bash tracing
#   --dry-run          Show what would be encoded without doing it
#   --keep             Keep source files after encoding (default: replace source)
#   --outdir DIR       Write encoded files to DIR instead of replacing in-place
#   --shallow          Only scan INPUT_DIR, do not recurse into subdirectories
#   --include-hevc     Also re-encode HEVC/H.265 sources (skipped by default)
#   --transcode-audio  Transcode lossless audio (TrueHD/DTS-MA/FLAC) to EAC3 640k
#   --no-abort         Disable abort on poor compression (for full library runs)
#   --min-size MB      Skip files smaller than MB megabytes (default: 500)
#   --skip-list FILE   Path to persistent skip list file (default: ~/.encode_av1_skiplist)
#   --no-skip-list     Disable the skip list for this run
#
# Behavior:
#   - Skips files whose video stream is already AV1 or HEVC (unless --include-hevc)
#   - Preserves all metadata, subtitles, and chapters
#   - Adds poorly-compressing files to skip list automatically
#   - Continues on encode failures (path too long, permission denied, etc.)

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

VAAPI_DEVICE="/dev/dri/renderD128"
GLOBAL_QUALITY=21
MIN_SAVINGS_PCT=10
OUTPUT_EXT="mkv"
AUDIO_TRANSCODE_BITRATE="640k"
MIN_FILE_SIZE_MB=500
SKIP_LIST_FILE="${HOME}/.encode_av1_skiplist"
EXTRA_FLAGS=""

# ── Argument parsing ──────────────────────────────────────────────────────────

DEBUG=0
KEEP_SOURCE=0
KEEP_EXPLICIT=0
DRY_RUN=0
SHALLOW=0
INCLUDE_HEVC=0
TRANSCODE_AUDIO=0
NO_ABORT=0
OUTPUT_DIR=""
INPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug|-d)        DEBUG=1; shift ;;
        --keep)            KEEP_SOURCE=1; KEEP_EXPLICIT=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --shallow)         SHALLOW=1; shift ;;
        --outdir)          OUTPUT_DIR="$2"; shift 2 ;;
        --include-hevc)    INCLUDE_HEVC=1; shift ;;
        --transcode-audio) TRANSCODE_AUDIO=1; shift ;;
        --no-abort)        NO_ABORT=1; shift ;;
        --min-size)        MIN_FILE_SIZE_MB="$2"; shift 2 ;;
        --skip-list)       SKIP_LIST_FILE="$2"; shift 2 ;;
        --no-skip-list)    SKIP_LIST_FILE=""; shift ;;
        -*)                echo "Unknown option: $1" >&2; exit 1 ;;
        *)                 INPUT_DIR="$1"; shift ;;
    esac
done

INPUT_DIR="${INPUT_DIR:-.}"
[[ -f "$INPUT_DIR" ]] && INPUT_DIR="$(dirname "$INPUT_DIR")"
INPUT_DIR="$(realpath "$INPUT_DIR" 2>/dev/null || echo "$INPUT_DIR")"

IN_PLACE=0
if [[ -z "$OUTPUT_DIR" ]]; then
    IN_PLACE=1
    [[ $KEEP_EXPLICIT -eq 0 ]] && KEEP_SOURCE=0
else
    OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR" 2>/dev/null || echo "$OUTPUT_DIR")"
fi

[[ $DEBUG -eq 1 ]] && set -x

# ── Colors ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; RESET='\033[0m'

log_info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_skip()   { echo -e "${YELLOW}[SKIP]${RESET}  $*"; }
log_error()  { echo -e "${RED}[ERR]${RESET}   $*" >&2; }
log_debug()  { [[ $DEBUG -eq 1 ]] && echo -e "${YELLOW}[DBG]${RESET}   $*" || true; }

# ── Sanity checks ─────────────────────────────────────────────────────────────

command -v ffmpeg  &>/dev/null || { log_error "ffmpeg not found"; exit 1; }
command -v ffprobe &>/dev/null || { log_error "ffprobe not found"; exit 1; }
[[ -c "$VAAPI_DEVICE" ]] || { log_error "DRI device not found: $VAAPI_DEVICE"; exit 1; }
[[ -d "$INPUT_DIR" ]] || { log_error "Input dir not found: $INPUT_DIR"; exit 1; }

# ── Debug diagnostics ─────────────────────────────────────────────────────────

if [[ $DEBUG -eq 1 ]]; then
    echo -e "\n${YELLOW}${BOLD}=== DEBUG MODE ===${RESET}"
    uname -r; ffmpeg -version 2>&1 | head -4; ffmpeg -hide_banner -hwaccels 2>&1
    ffmpeg -hide_banner -encoders 2>&1 | grep -i qsv || echo "(no QSV encoders)"
    ls -la /dev/dri/ 2>&1
    command -v vainfo &>/dev/null && vainfo --display drm --device "${VAAPI_DEVICE}" 2>&1 || echo "(vainfo not found)"
    echo ""
    
    log_info "Running QSV AV1 smoke-test..."
    if ! ffmpeg -hide_banner -loglevel debug -stats \
        -init_hw_device "vaapi=va:${VAAPI_DEVICE}" \
        -init_hw_device "qsv=hw@va" \
        -filter_hw_device hw \
        -f lavfi -i "nullsrc=s=256x144:r=24" -vframes 4 \
        -vf "format=p010le,hwupload=extra_hw_frames=8,format=qsv" \
        -c:v av1_qsv -global_quality "${GLOBAL_QUALITY}" \
        -look_ahead 1 -low_power 0 -b_strategy 1 -adaptive_i 1 -adaptive_b 1 \
        -f null - 2>&1; then
        log_error "QSV AV1 smoke-test failed"
        exit 1
    fi
    log_ok "Smoke-test passed"
    echo ""
fi

# ── Skip list ─────────────────────────────────────────────────────────────────

if [[ -n "$SKIP_LIST_FILE" ]] && [[ -f "$SKIP_LIST_FILE" ]]; then
    skip_count="$(wc -l < "$SKIP_LIST_FILE")"
    log_info "Skip list: ${skip_count} file(s) (${SKIP_LIST_FILE})"
fi

# ── Helper functions ──────────────────────────────────────────────────────────

get_video_codec() {
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -1
}

get_video_pixfmt() {
    ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt \
        -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -1
}

get_file_size_bytes() {
    stat -c %s "$1" 2>/dev/null || echo 0
}

get_file_size_mb() {
    local bytes=$(get_file_size_bytes "$1")
    awk -v b="$bytes" 'BEGIN {printf "%.0f", b/1048576}'
}

get_bitrate_kbps() {
    ffprobe -v error -show_entries format=bit_rate \
        -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | awk '{printf "%.0f", $1/1000}'
}

get_hdr_format() {
    local file="$1"
    local side_data=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream_side_data_list=side_data_type \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    
    if echo "$side_data" | grep -qi "dovi\|dolby"; then
        echo "dovi"
    elif echo "$side_data" | grep -qi "hdr10+\|hdr10_plus"; then
        echo "hdr10plus"
    elif echo "$side_data" | grep -qi "hdr10\|mastering"; then
        echo "hdr10"
    fi
}

has_lossless_audio() {
    ffprobe -v error -select_streams a -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | grep -qiE "truehd|dts|flac"
}

has_variable_resolution() {
    local count=$(ffprobe -v error -select_streams v:0 \
        -show_entries frame=width,height -of default=noprint_wrappers=1:nokey=1 \
        -read_intervals "%+#120" "$1" 2>/dev/null | paste - - | sort -u | wc -l)
    [[ "${count:-1}" -gt 1 ]]
}

is_in_skip_list() {
    [[ -z "$SKIP_LIST_FILE" ]] && return 1
    [[ ! -f "$SKIP_LIST_FILE" ]] && return 1
    grep -qxF "$1" "$SKIP_LIST_FILE"
}

add_to_skip_list() {
    [[ -z "$SKIP_LIST_FILE" ]] && return
    echo "$1" >> "$SKIP_LIST_FILE"
}

fmt_duration() {
    local s=$1
    printf '%02d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60))
}

test_filter_compatibility() {
    local input="$1" vf_chain="$2" use_hw_decode="$3"
    local tmpfile=$(mktemp)
    local hw_decode_flags=()
    
    [[ $use_hw_decode -eq 1 ]] && hw_decode_flags=(-hwaccel qsv -hwaccel_output_format qsv)
    
    ffmpeg -hide_banner -loglevel error -stats \
        -init_hw_device "vaapi=va:${VAAPI_DEVICE}" \
        -init_hw_device "qsv=hw@va" \
        -filter_hw_device hw \
        "${hw_decode_flags[@]}" \
        -i "$input" -map 0:V:0 -vf "${vf_chain}" -c:v av1_qsv \
        -global_quality "${GLOBAL_QUALITY}" -vframes 1 -f null - &>"$tmpfile"
    
    local exit_code=$?
    local output=$(cat "$tmpfile")
    rm -f "$tmpfile"
    
    echo "$output" | grep -qi "Impossible to convert between the formats\|Task finished with error code: -38" && return 1
    return $exit_code
}

build_audio_flags() {
    local input="$1"
    
    if [[ $TRANSCODE_AUDIO -eq 0 ]]; then
        echo "-c:a copy"
        return
    fi
    
    local result=() idx=0
    while IFS= read -r codec_name; do
        case "${codec_name,,}" in
            truehd|dts|flac)
                result+=("-c:a:${idx}" "eac3" "-b:a:${idx}" "${AUDIO_TRANSCODE_BITRATE}")
                ;;
            *)
                result+=("-c:a:${idx}" "copy")
                ;;
        esac
        idx=$(( idx + 1 ))
    done < <(ffprobe -v error -select_streams a -show_entries stream=codec_name \
                 -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)
    
    echo "${result[*]}"
}

# ── Encode function ───────────────────────────────────────────────────────────

encode_file() {
    local input="$1" status_file="$2"
    local filename=$(basename "${input%.*}")
    
    # Determine output paths
    local output_dir tmp_output output
    if [[ $IN_PLACE -eq 1 ]]; then
        output_dir="$(dirname "$input")"
        tmp_output="${output_dir}/${filename}.av1tmp.${OUTPUT_EXT}"
        output="${output_dir}/${filename}.${OUTPUT_EXT}"
    else
        local rel_dir=$(dirname "$(realpath --relative-to="$INPUT_DIR" "$input")")
        output_dir=$(realpath -m "${OUTPUT_DIR}/${rel_dir}")
        mkdir -p "$output_dir"
        tmp_output="${output_dir}/${filename}.${OUTPUT_EXT}"
        output="${output_dir}/${filename}.${OUTPUT_EXT}"
    fi
    
    # Check output path length
    if [[ ${#output} -ge 255 ]]; then
        log_error "Output path too long (${#output} chars): $(basename "$input")"
        add_to_skip_list "$input"
        echo "FAIL" > "$status_file"
        return 0
    fi
    
    # Skip if output exists
    if [[ $IN_PLACE -eq 0 ]] && [[ -f "$output" ]]; then
        log_skip "Output exists: $(basename "$input")"
        echo "SKIP" > "$status_file"
        return 0
    fi
    
    # Validate and check codec
    local codec=$(get_video_codec "$input") || codec=""
    if [[ -z "$codec" ]]; then
        log_skip "No video stream or corrupted: $(basename "$input")"
        echo "SKIP" > "$status_file"
        return 0
    fi
    
    case "${codec,,}" in
        av1)
            log_skip "Already AV1: $(basename "$input")"
            echo "SKIP" > "$status_file"
            return 0
            ;;
        hevc|h265)
            if [[ $INCLUDE_HEVC -eq 0 ]]; then
                log_skip "HEVC (use --include-hevc): $(basename "$input")"
                echo "SKIP" > "$status_file"
                return 0
            fi
            ;;
    esac
    
    # Check skip list
    if is_in_skip_list "$input"; then
        log_skip "In skip list: $(basename "$input")"
        echo "SKIP" > "$status_file"
        return 0
    fi
    
    # Check file size
    local file_mb=$(get_file_size_mb "$input")
    if (( file_mb < MIN_FILE_SIZE_MB )); then
        log_skip "Too small (${file_mb}MB < ${MIN_FILE_SIZE_MB}MB): $(basename "$input")"
        echo "SKIP" > "$status_file"
        return 0
    fi
    
    # Gather source info
    local src_size=$(get_file_size_mb "$input")
    local src_bitrate=$(get_bitrate_kbps "$input")
    local hdr_format=$(get_hdr_format "$input")
    local src_pixfmt=$(get_video_pixfmt "$input")
    local has_lossless=0
    has_lossless_audio "$input" && has_lossless=1
    
    # Determine decode path
    local use_hw_decode=1
    if [[ "${codec,,}" == "h264" ]] && [[ "$src_pixfmt" == *"10"* ]]; then
        use_hw_decode=0
        log_debug "10-bit H.264: using software decode"
    fi
    
    local hdr_label=""
    [[ -n "$hdr_format" ]] && hdr_label=" ${YELLOW}[${hdr_format^^}]${RESET}${CYAN}"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[${codec}]${hdr_label:- } ${src_size}MB @ ${src_bitrate}kbps -> $(basename "$output")"
        [[ $has_lossless -eq 1 && $TRANSCODE_AUDIO -eq 1 ]] && \
            log_info "  Audio: lossless -> EAC3 ${AUDIO_TRANSCODE_BITRATE}"
        echo "SKIP" > "$status_file"
        return 0
    fi
    
    log_info "Encoding [${BOLD}${codec}${RESET}${CYAN}]${hdr_label} -> AV1: $(basename "$input") (${src_size}MB, ${src_bitrate}kbps)"
    [[ -n "$hdr_format" ]] && log_info "  HDR: ${hdr_format^^}"
    [[ $has_lossless -eq 1 ]] && log_info "  Audio: lossless ($(
        [[ $TRANSCODE_AUDIO -eq 1 ]] && echo "-> EAC3 ${AUDIO_TRANSCODE_BITRATE}" || echo "copying"))"
    
    # Check for variable resolution
    if has_variable_resolution "$input"; then
        use_hw_decode=0
        log_debug "Variable resolution: falling back to software decode"
        log_info "Variable resolution detected"
    fi
    
    # Build filter chain
    local vf_chain
    if [[ $use_hw_decode -eq 1 ]]; then
        vf_chain="scale_qsv=w=-1:h=-1:format=p010le,hwupload=extra_hw_frames=64"
    else
        vf_chain="format=p010le,hwupload=extra_hw_frames=64"
    fi
    
    # Test filter compatibility
    log_debug "Testing filter compatibility..."
    if ! test_filter_compatibility "$input" "$vf_chain" "$use_hw_decode"; then
        log_skip "Filter incompatible: $(basename "$input")"
        add_to_skip_list "$input"
        echo "SKIP" > "$status_file"
        return 0
    fi
    
    # Build ffmpeg command
    local hw_decode_flags=()
    [[ $use_hw_decode -eq 1 ]] && hw_decode_flags=(-hwaccel qsv -hwaccel_output_format qsv)
    
    local audio_flags=$(build_audio_flags "$input")
    
    local ff_cmd=(
        ffmpeg -hide_banner -loglevel warning -stats
        ${EXTRA_FLAGS:+${EXTRA_FLAGS}}
        -init_hw_device "vaapi=va:${VAAPI_DEVICE}"
        -init_hw_device "qsv=hw@va"
        -filter_hw_device hw
        "${hw_decode_flags[@]}"
        -i "$input"
        -map 0:V:0 -map 0:a? -map 0:s? -map 0:t?
        -map_chapters 0 -map_metadata 0
        -vf "${vf_chain}"
        -c:v av1_qsv
        -global_quality "${GLOBAL_QUALITY}"
        -look_ahead 1 -look_ahead_depth 40
        -b_strategy 1 -adaptive_i 1 -adaptive_b 1
        -g 120 -low_power 0
        ${audio_flags}
        -c:s copy
        "$tmp_output"
    )
    
    log_debug "FFmpeg: ${ff_cmd[*]}"
    
    # Run encode and capture stderr
    local ffmpeg_stderr
    ffmpeg_stderr=$("${ff_cmd[@]}" 2>&1 | grep -v -E '^libva info:|^libva warning:|Error parsing Opus packet header' >&2) || true
    local ff_exit=${PIPESTATUS[0]}
    
    # Handle output file errors
    if echo "$ffmpeg_stderr" | grep -qi "File name too long\|No such file or directory\|Permission denied\|Read-only file system"; then
        log_error "Output file error: $(basename "$input")"
        add_to_skip_list "$input"
        rm -f "$tmp_output"
        echo "FAIL" > "$status_file"
        return 0
    fi
    
    if [[ $ff_exit -ne 0 ]]; then
        log_error "Encode failed (exit ${ff_exit}): $(basename "$input")"
        add_to_skip_list "$input"
        rm -f "$tmp_output"
        echo "FAIL" > "$status_file"
        return 0
    fi
    
    # Post-encode size check
    local src_bytes=$(get_file_size_bytes "$input")
    local dst_bytes=$(get_file_size_bytes "$tmp_output")
    local dst_size=$(get_file_size_mb "$tmp_output")
    local dst_bitrate=$(get_bitrate_kbps "$tmp_output")
    
    if [[ -z "$dst_bytes" ]] || [[ "$dst_bytes" -eq 0 ]]; then
        log_error "Could not read output file size"
        rm -f "$tmp_output"
        echo "FAIL" > "$status_file"
        return 0
    fi
    
    local savings_pct=$(awk -v a="$dst_bytes" -v b="${src_bytes:-1}" \
        'BEGIN {printf "%.1f", 100-(a/b)*100}')
    local bitrate_pct=$(awk -v a="$dst_bitrate" -v b="${src_bitrate:-1}" \
        'BEGIN {printf "%.1f", (a/b)*100}')
    local savings_int=$(awk -v a="$dst_bytes" -v b="${src_bytes:-1}" \
        'BEGIN {printf "%d", 100-(a/b)*100}')
    
    if (( savings_int < MIN_SAVINGS_PCT )); then
        log_skip "Only ${savings_pct}% savings (threshold: ${MIN_SAVINGS_PCT}%): $(basename "$input")"
        add_to_skip_list "$input"
        rm -f "$tmp_output"
        echo "LARGER" > "$status_file"
        return 0
    fi
    
    log_ok "Done: $(basename "$output")"
    echo -e "       Size: ${src_size}MB -> ${dst_size}MB (${savings_pct}% smaller)"
    echo -e "       Rate: ${src_bitrate}kbps -> ${dst_bitrate}kbps (${bitrate_pct}% of original)"
    
    # Replace or move output
    safe_move() {
        mv -f "$1" "$2" 2>/dev/null || { cp "$1" "$2" && rm -f "$1"; }
    }
    
    if [[ $IN_PLACE -eq 1 ]]; then
        if [[ $KEEP_SOURCE -eq 0 ]]; then
            rm -f "$input"
            safe_move "$tmp_output" "$input"
        else
            safe_move "$tmp_output" "${output_dir}/${filename}.av1.${OUTPUT_EXT}"
        fi
    else
        [[ $KEEP_SOURCE -eq 0 ]] && rm -f "$input"
    fi
    
    echo "OK" > "$status_file"
}

# ── Startup cleanup ───────────────────────────────────────────────────────────

FIND_DEPTH=()
[[ $SHALLOW -eq 1 ]] && FIND_DEPTH=(-maxdepth 1)

mapfile -t LEFTOVER < <(find "$INPUT_DIR" "${FIND_DEPTH[@]}" -type f \
    -name "*.av1tmp.${OUTPUT_EXT}" 2>/dev/null)

if [[ ${#LEFTOVER[@]} -gt 0 ]]; then
    echo -e "${YELLOW}-- Cleaning up ${#LEFTOVER[@]} leftover temp files --${RESET}"
    for lf in "${LEFTOVER[@]}"; do
        log_skip "Removing: $(basename "$lf")"
        rm -f "$lf"
    done
    echo ""
fi

# ── File discovery ────────────────────────────────────────────────────────────

[[ $IN_PLACE -eq 0 ]] && mkdir -p "$OUTPUT_DIR"

mapfile -t FILES < <(find "$INPUT_DIR" "${FIND_DEPTH[@]}" -type f \( \
    -iname "*.mkv"  -o -iname "*.mp4"  -o -iname "*.mov" -o \
    -iname "*.avi"  -o -iname "*.ts"   -o -iname "*.m2ts" -o \
    -iname "*.wmv"  -o -iname "*.flv"  -o -iname "*.webm" -o \
    -iname "*.mpg"  -o -iname "*.mpeg" -o -iname "*.m4v" \) | sort)

# ── Banner ────────────────────────────────────────────────────────────────────

echo -e "\n${BOLD}=== Intel Arc B580 QSV -> AV1 Batch Encoder ===${RESET}"
echo -e "  Input     : ${CYAN}${INPUT_DIR}${RESET} $(
    [[ $SHALLOW -eq 1 ]] && echo '(shallow)' || echo '(recursive)')"
echo -e "  Output    : $(
    [[ $IN_PLACE -eq 1 ]] && echo "${CYAN}in-place${RESET} (replace source)" || echo "${CYAN}${OUTPUT_DIR}${RESET}")"
echo -e "  Quality   : ICQ ${GLOBAL_QUALITY}  |  Min savings: ${MIN_SAVINGS_PCT}%  |  Min size: ${MIN_FILE_SIZE_MB}MB"
echo -e "  Device    : ${VAAPI_DEVICE}"
echo -e "  Keep src  : $([[ $KEEP_SOURCE -eq 1 ]] && echo 'yes' || echo 'no')"
echo -e "  HEVC      : $([[ $INCLUDE_HEVC -eq 1 ]] && echo "${YELLOW}encode${RESET}" || echo 'skip')"
echo -e "  Audio     : $([[ $TRANSCODE_AUDIO -eq 1 ]] && echo "${YELLOW}transcode lossless${RESET}" || echo 'copy all')"
echo -e "  Dry run   : $([[ $DRY_RUN -eq 1 ]] && echo "${MAGENTA}YES${RESET}" || echo 'no')"
echo -e "  Debug     : $([[ $DEBUG -eq 1 ]] && echo "${YELLOW}ON${RESET}" || echo 'off')"

if [[ ${#FILES[@]} -eq 0 ]]; then
    log_skip "No video files found in: ${INPUT_DIR}"
    exit 0
fi

echo -e "  Files     : ${#FILES[@]} found\n"

# ── Export for subshells ──────────────────────────────────────────────────────

export -f encode_file build_audio_flags is_in_skip_list add_to_skip_list \
          get_video_codec get_video_pixfmt get_file_size_bytes get_file_size_mb \
          get_bitrate_kbps get_hdr_format has_lossless_audio has_variable_resolution \
          fmt_duration test_filter_compatibility log_info log_ok log_skip log_error log_debug

export VAAPI_DEVICE GLOBAL_QUALITY OUTPUT_EXT MIN_SAVINGS_PCT MIN_FILE_SIZE_MB \
       SKIP_LIST_FILE AUDIO_TRANSCODE_BITRATE EXTRA_FLAGS IN_PLACE OUTPUT_DIR INPUT_DIR \
       KEEP_SOURCE DRY_RUN DEBUG INCLUDE_HEVC TRANSCODE_AUDIO \
       RED GREEN YELLOW CYAN MAGENTA BOLD RESET

# ── Main loop ─────────────────────────────────────────────────────────────────

COUNT_OK=0; COUNT_FAIL=0; COUNT_SKIP=0; COUNT_LARGER=0
TOTAL_SRC_MB=0; TOTAL_DST_MB=0
BATCH_START=$(date +%s)
ENCODE_TIMES=()
TOTAL=${#FILES[@]}

for i in "${!FILES[@]}"; do
    f="${FILES[$i]}"
    FILE_NUM=$(( i + 1 ))
    ELAPSED=$(( $(date +%s) - BATCH_START ))
    
    # ETA calculation
    if [[ ${#ENCODE_TIMES[@]} -gt 0 ]]; then
        local sum_t=0
        for t in "${ENCODE_TIMES[@]}"; do sum_t=$(( sum_t + t )); done
        local avg_t=$(( sum_t / ${#ENCODE_TIMES[@]} ))
        local remain_t=$(( (TOTAL - FILE_NUM) * avg_t ))
        local ETA_STR="ETA $(fmt_duration $remain_t)"
    else
        local ETA_STR="ETA --:--:--"
    fi
    
    echo -e "${BOLD}-- [${FILE_NUM}/${TOTAL}] ${ETA_STR} | elapsed $(fmt_duration $ELAPSED) --${RESET}"
    
    FILE_START=$(date +%s)
    src_bytes=$(get_file_size_bytes "$f")
    
    STATUS_FILE=$(mktemp)
    encode_file "$f" "$STATUS_FILE"
    STATUS=$(cat "$STATUS_FILE")
    rm -f "$STATUS_FILE"
    
    FILE_ELAPSED=$(( $(date +%s) - FILE_START ))
    
    case "$STATUS" in
        OK)
            COUNT_OK=$(( COUNT_OK + 1 ))
            ENCODE_TIMES+=("$FILE_ELAPSED")
            TOTAL_SRC_MB=$(( TOTAL_SRC_MB + src_bytes / 1048576 ))
            filename_base=$(basename "${f%.*}")
            if [[ $IN_PLACE -eq 1 ]]; then
                out_check="$(dirname "$f")/${filename_base}.${OUTPUT_EXT}"
            else
                rel=$(dirname "$(realpath --relative-to="$INPUT_DIR" "$f")")
                out_check="${OUTPUT_DIR}/${rel}/${filename_base}.${OUTPUT_EXT}"
            fi
            [[ -f "$out_check" ]] && TOTAL_DST_MB=$(( TOTAL_DST_MB + $(get_file_size_mb "$out_check") ))
            ;;
        FAIL)
            COUNT_FAIL=$(( COUNT_FAIL + 1 ))
            ;;
        SKIP)
            COUNT_SKIP=$(( COUNT_SKIP + 1 ))
            ;;
        LARGER)
            COUNT_SKIP=$(( COUNT_SKIP + 1 ))
            COUNT_LARGER=$(( COUNT_LARGER + 1 ))
            ;;
    esac
done

# ── Session summary ───────────────────────────────────────────────────────────

BATCH_END=$(date +%s)
TOTAL_ELAPSED=$(( BATCH_END - BATCH_START ))

SAVED_MB=$(( TOTAL_SRC_MB - TOTAL_DST_MB ))
if [[ $TOTAL_SRC_MB -gt 0 ]]; then
    SAVED_PCT=$(awk -v s="$SAVED_MB" -v t="$TOTAL_SRC_MB" 'BEGIN {printf "%.1f", (s/t)*100}')
else
    SAVED_PCT="0.0"
fi

echo -e "\n${BOLD}+===================================+${RESET}"
echo -e "${BOLD}|         SESSION SUMMARY           |${RESET}"
echo -e "${BOLD}+===================================+${RESET}"
echo -e "  Encoded   : ${GREEN}${COUNT_OK}${RESET} files"
echo -e "  Skipped   : ${YELLOW}${COUNT_SKIP}${RESET} files"
echo -e "  No saving : ${YELLOW}${COUNT_LARGER}${RESET} files"
echo -e "  Failed    : ${RED}${COUNT_FAIL}${RESET} files"
if [[ $TOTAL_SRC_MB -gt 0 ]]; then
    echo -e "  Input     : ${TOTAL_SRC_MB}MB"
    echo -e "  Output    : ${TOTAL_DST_MB}MB"
    echo -e "  Saved     : ${GREEN}${SAVED_MB}MB (${SAVED_PCT}%)${RESET}"
fi
echo -e "  Duration  : $(fmt_duration $TOTAL_ELAPSED)"
[[ $DRY_RUN -eq 1 ]] && echo -e "\n  ${MAGENTA}(dry run -- no files modified)${MAGENTA}"
echo ""

[[ $COUNT_FAIL -gt 0 ]] && exit 1 || exit 0
