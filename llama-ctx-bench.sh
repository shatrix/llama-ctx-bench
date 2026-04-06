#!/usr/bin/env bash
# llama-ctx-bench.sh — Context load tester for llama.cpp server
# Connects to a remote llama.cpp server via HTTP to measure context handling.
# NOTE: GPU/VRAM metrics are sourced from the server's /metrics endpoint (Prometheus format).
#       For NVIDIA-specific GPU memory details, run nvidia-smi directly on the server.
#       Multi-GPU: KV cache metrics reflect total usage across all GPUs.
# Usage: ./llama-ctx-bench.sh -h <host> -p <port> -m <model> -c <ctx_tokens>
# Example: ./llama-ctx-bench.sh -h 192.168.1.10 -p 8080 -m Nemotron-30B-Q4 -c 64000

set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────────────
HOST="localhost"
PORT="8080"
MODEL=""
CTX_TARGET=32000
MAX_GEN_TOKENS=10      # keep tiny — we only care about prefill
REQUEST_TIMEOUT=600    # seconds

# ── colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

# ── helpers ──────────────────────────────────────────────────────────────────
usage() {
    local exit_code=${1:-0}
    cat <<EOF
Usage: $0 -m <model_name> [options]

Required:
  -m MODEL      Model name as registered in llama-server

Options:
  -h HOST       Server host (default: localhost)
  -p PORT       Server port (default: 8080)
  -c TOKENS     Target context tokens to fill (default: 32000)
  -t TIMEOUT    Request timeout in seconds (default: 600)
  --help        Show this help

Examples:
  $0 -m Nemotron-30B-Q4 -c 64000
  $0 -h 192.168.1.10 -p 8080 -m Qwen3.5-35B-A3B -c 64000
EOF
    exit "$exit_code"
}

is_positive_int() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]
}

check_deps() {
    local missing=()
    for cmd in curl jq bc python3; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Missing dependencies: ${missing[*]}${RST}"
        echo "Install with: sudo apt install ${missing[*]}"
        exit 1
    fi
}

separator() { echo -e "${CYN}────────────────────────────────────────────────────────${RST}"; }
header()    { echo -e "\n${BLD}${YLW}$1${RST}"; separator; }

now_ms() {
    # Portable millisecond timestamp — works on GNU, BSD, and macOS
    python3 -c 'import time; print(int(time.time() * 1000))'
}

fmt_ms() {
    local ms=$1
    if (( $(echo "$ms >= 60000" | bc -l) )); then
        echo "$(echo "scale=2; $ms/60000" | bc) min"
    elif (( $(echo "$ms >= 1000" | bc -l) )); then
        echo "$(echo "scale=2; $ms/1000" | bc) s"
    else
        echo "${ms} ms"
    fi
}

# ── arg parsing ──────────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage
while [[ $# -gt 0 ]]; do
    case $1 in
        -h)
            [[ $# -lt 2 ]] && { echo -e "${RED}Error: -h requires a value${RST}"; usage 1; }
            HOST="$2"; shift 2 ;;
        -p)
            [[ $# -lt 2 ]] && { echo -e "${RED}Error: -p requires a value${RST}"; usage 1; }
            is_positive_int "$2" || { echo -e "${RED}Error: -p must be a positive integer, got '$2'${RST}"; usage 1; }
            PORT="$2"; shift 2 ;;
        -m)
            [[ $# -lt 2 ]] && { echo -e "${RED}Error: -m requires a value${RST}"; usage 1; }
            MODEL="$2"; shift 2 ;;
        -c)
            [[ $# -lt 2 ]] && { echo -e "${RED}Error: -c requires a value${RST}"; usage 1; }
            is_positive_int "$2" || { echo -e "${RED}Error: -c must be a positive integer, got '$2'${RST}"; usage 1; }
            CTX_TARGET="$2"; shift 2 ;;
        -t)
            [[ $# -lt 2 ]] && { echo -e "${RED}Error: -t requires a value${RST}"; usage 1; }
            is_positive_int "$2" || { echo -e "${RED}Error: -t must be a positive integer, got '$2'${RST}"; usage 1; }
            REQUEST_TIMEOUT="$2"; shift 2 ;;
        --help) usage ;;
        *) echo -e "${RED}Unknown option: $1${RST}"; usage 1 ;;
    esac
done

[[ -z "$MODEL" ]] && { echo -e "${RED}Error: model name is required (-m)${RST}"; usage 1; }

BASE_URL="http://${HOST}:${PORT}"

# ── dependency check ─────────────────────────────────────────────────────────
check_deps

# ── banner ───────────────────────────────────────────────────────────────────
echo -e "\n${BLD}╔══════════════════════════════════════════════╗"
echo -e "║     llama-ctx-bench  —  Context load test    ║"
echo -e "╚══════════════════════════════════════════════╝${RST}"
echo -e "  Server  : ${CYN}${BASE_URL}${RST}"
echo -e "  Model   : ${CYN}${MODEL}${RST}"
echo -e "  Target  : ${CYN}${CTX_TARGET} tokens${RST}"
echo -e "  Time    : $(date '+%Y-%m-%d %H:%M:%S')"

# ── 1. server health check ───────────────────────────────────────────────────
header "1 / 5  Server health"
HEALTH=$(curl -sf --max-time 10 "${BASE_URL}/health" 2>/dev/null || echo '{"status":"unreachable"}')
STATUS=$(echo "$HEALTH" | jq -r '.status // "unknown"')
if [[ "$STATUS" == "ok" ]]; then
    echo -e "  Status  : ${GRN}${STATUS}${RST}"
else
    echo -e "  Status  : ${RED}${STATUS}${RST}"
    echo -e "  ${RED}Server not healthy — aborting.${RST}"
    exit 1
fi

# ── 2. server props (model info) ─────────────────────────────────────────────
header "2 / 5  Model info"
PROPS=$(curl -sf --max-time 10 "${BASE_URL}/props" 2>/dev/null || echo '{}')
CTX_SIZE=$(echo "$PROPS"   | jq -r '.total_slots? // "n/a"')
N_CTX=$(echo "$PROPS"      | jq -r '.n_ctx? // "n/a"')
CHAT_TMPL=$(echo "$PROPS"  | jq -r '.chat_template? // "n/a"' | cut -c1-60)
MODEL_META=$(echo "$PROPS" | jq -r '.model_meta? // {} | to_entries[] | "  \(.key): \(.value)"' 2>/dev/null | head -20 || true)

echo -e "  n_ctx         : ${CYN}${N_CTX}${RST}"
echo -e "  total_slots   : ${CYN}${CTX_SIZE}${RST}"
echo -e "  chat_template : ${CYN}${CHAT_TMPL}...${RST}"
[[ -n "$MODEL_META" ]] && echo -e "$MODEL_META"

# ── 3. pre-request server metrics ───────────────────────────────────────────
header "3 / 5  Server metrics (pre-request)"

METRICS_PRE=$(curl -sf --max-time 10 "${BASE_URL}/metrics" 2>/dev/null || echo "")

if [[ -n "$METRICS_PRE" ]]; then
    KV_USAGE_PRE=$(echo "$METRICS_PRE" | grep -m1 'llamacpp:kv_cache_usage_ratio' | awk '{print $2}' || echo "n/a")
    KV_TOKENS_PRE=$(echo "$METRICS_PRE" | grep -m1 'llamacpp:kv_cache_tokens' | awk '{print $2}' || echo "n/a")
    SLOTS_ACTIVE_PRE=$(echo "$METRICS_PRE" | grep -m1 'llamacpp:slots_active' | awk '{print $2}' || echo "n/a")
    SLOTS_IDLE_PRE=$(echo "$METRICS_PRE" | grep -m1 'llamacpp:slots_idle' | awk '{print $2}' || echo "n/a")

    echo -e "  KV cache usage : ${CYN}${KV_USAGE_PRE:-n/a}${RST}"
    echo -e "  KV cache tokens: ${CYN}${KV_TOKENS_PRE:-n/a}${RST}"
    echo -e "  Active slots   : ${CYN}${SLOTS_ACTIVE_PRE:-n/a}${RST}"
    echo -e "  Idle slots     : ${CYN}${SLOTS_IDLE_PRE:-n/a}${RST}"
else
    echo -e "  ${YLW}Warning: Could not fetch server metrics${RST}"
    KV_USAGE_PRE="n/a"; KV_TOKENS_PRE="n/a"; SLOTS_ACTIVE_PRE="n/a"; SLOTS_IDLE_PRE="n/a"
fi

# ── 4. build prompt & fire request ──────────────────────────────────────────
header "4 / 5  Sending context-fill request"

# tokens/chars ratio: "The quick brown fox jumps over the lazy dog. " = 45 chars ~ 10 tokens
# so chars_needed = ctx_target * 5 (conservative — better to overshoot slightly)
CHARS_NEEDED=$(( CTX_TARGET * 5 ))
REPEAT_UNIT="The quick brown fox jumps over the lazy dog. "
UNIT_LEN=${#REPEAT_UNIT}
REPEATS=$(( CHARS_NEEDED / UNIT_LEN + 1 ))

echo -e "  Generating filler : ${REPEATS} repetitions (~${CHARS_NEEDED} chars)"

# Build the JSON payload entirely in python3 and write it to a temp file.
# This avoids the OS "Argument list too long" error that occurs when passing
# large strings (300k+ chars) as shell arguments to jq or curl -d.
PAYLOAD_FILE=$(mktemp /tmp/llama-ctx-bench-XXXXXX.json)
trap 'rm -f "$PAYLOAD_FILE"' EXIT

python3 -c "
import json
unit    = 'The quick brown fox jumps over the lazy dog. '
payload = {
    'model':    '$MODEL',
    'messages': [{'role': 'user', 'content': unit * $REPEATS}],
    'max_tokens': $MAX_GEN_TOKENS,
    'temperature': 0,
    'stream': False
}
with open('$PAYLOAD_FILE', 'w') as fh:
    json.dump(payload, fh)
"

echo -e "  Firing request... (timeout: ${REQUEST_TIMEOUT}s)"
START_TS=$(now_ms)

RESPONSE=$(curl -sf \
    --max-time "$REQUEST_TIMEOUT" \
    -X POST "${BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "@${PAYLOAD_FILE}" 2>/dev/null || echo '{"error":"request_failed"}')

END_TS=$(now_ms)
WALL_MS=$(( END_TS - START_TS ))

# post-request metrics from server
METRICS_POST=$(curl -sf --max-time 10 "${BASE_URL}/metrics" 2>/dev/null || echo "")

# ── 5. results ───────────────────────────────────────────────────────────────
header "5 / 5  Results"

# check for error
ERR=$(echo "$RESPONSE" | jq -r '.error? // empty' 2>/dev/null || true)
if [[ -n "$ERR" ]]; then
    echo -e "  ${RED}Request failed: ${ERR}${RST}"
    exit 1
fi

# usage — use awk for float-safe arithmetic
PROMPT_TOKENS=$(echo "$RESPONSE"  | jq -r '.usage.prompt_tokens // 0')
COMPL_TOKENS=$(echo "$RESPONSE"   | jq -r '.usage.completion_tokens // 0')
TOTAL_TOKENS=$(echo "$RESPONSE"   | jq -r '.usage.total_tokens // 0')
CACHED_TOKENS=$(echo "$RESPONSE"  | jq -r '.usage.prompt_tokens_details.cached_tokens // 0')
FRESH_TOKENS=$(awk "BEGIN {printf \"%.0f\", $PROMPT_TOKENS - $CACHED_TOKENS}")

# timings (from response if available)
TIMINGS=$(echo "$RESPONSE" | jq '.timings? // {}')
T_PROMPT_MS=$(echo "$TIMINGS"  | jq -r '.prompt_ms // 0')
T_PREDICT_MS=$(echo "$TIMINGS" | jq -r '.predict_ms // 0')
T_TOTAL_MS=$(echo "$TIMINGS"   | jq -r '.total_ms // 0')
PROMPT_TPS=$(echo "$TIMINGS"   | jq -r '.prompt_per_second // 0')
PREDICT_TPS=$(echo "$TIMINGS"  | jq -r '.predicted_per_second // 0')

# Server-side metrics
KV_USAGE_POST=""
KV_TOKENS_POST=""
SLOTS_ACTIVE_POST=""
SLOTS_IDLE_POST=""
if [[ -n "$METRICS_POST" ]]; then
    KV_USAGE_POST=$(echo "$METRICS_POST" | grep -m1 'llamacpp:kv_cache_usage_ratio' | awk '{print $2}' || echo "n/a")
    KV_TOKENS_POST=$(echo "$METRICS_POST" | grep -m1 'llamacpp:kv_cache_tokens' | awk '{print $2}' || echo "n/a")
    SLOTS_ACTIVE_POST=$(echo "$METRICS_POST" | grep -m1 'llamacpp:slots_active' | awk '{print $2}' || echo "n/a")
    SLOTS_IDLE_POST=$(echo "$METRICS_POST" | grep -m1 'llamacpp:slots_idle' | awk '{print $2}' || echo "n/a")
fi

# KV cache delta
KV_DELTA=""
if [[ "$KV_TOKENS_PRE" != "n/a" && "$KV_TOKENS_POST" != "n/a" ]]; then
    KV_DELTA=$(awk "BEGIN {printf \"%.0f\", $KV_TOKENS_POST - $KV_TOKENS_PRE}")
    [[ "$KV_DELTA" =~ ^- ]] && KV_DELTA="~$((-1 * KV_DELTA)) cleared"
fi

echo ""
echo -e "  ${BLD}── Token counts ──────────────────────────────${RST}"
echo -e "  Prompt tokens   : ${CYN}${PROMPT_TOKENS}${RST}"
CACHE_NOTE=$(awk "BEGIN {print ($CACHED_TOKENS > 0) ? \"(cache hit — run again for cold result)\" : \"(cold run)\"}")
echo -e "  Cached tokens   : ${CYN}${CACHED_TOKENS}${RST}  ${CACHE_NOTE}"
echo -e "  Fresh tokens    : ${CYN}${FRESH_TOKENS}${RST}"
echo -e "  Generated tokens: ${CYN}${COMPL_TOKENS}${RST}"
echo -e "  Total tokens    : ${CYN}${TOTAL_TOKENS}${RST}"

echo ""
echo -e "  ${BLD}── Timings ───────────────────────────────────${RST}"
echo -e "  Wall clock total: ${CYN}$(fmt_ms $WALL_MS)${RST}"
if [[ "$T_PROMPT_MS" != "0" ]]; then
    echo -e "  Prefill time    : ${CYN}$(fmt_ms $(echo "$T_PROMPT_MS" | awk '{printf "%.0f", $1}'))${RST}"
    echo -e "  Generate time   : ${CYN}$(fmt_ms $(echo "$T_PREDICT_MS" | awk '{printf "%.0f", $1}'))${RST}"
    echo -e "  Prefill speed   : ${CYN}$(printf '%.1f' $PROMPT_TPS) t/s${RST}"
    echo -e "  Generate speed  : ${CYN}$(printf '%.1f' $PREDICT_TPS) t/s${RST}"
else
    echo -e "  (timings not returned by server for this model)"
fi

echo ""
echo -e "  ${BLD}── Server metrics (post-request) ─────────────────${RST}"
echo -e "  KV cache usage : ${CYN}${KV_USAGE_POST:-n/a}${RST}"
echo -e "  KV cache tokens: ${CYN}${KV_TOKENS_POST:-n/a}${RST}"
echo -e "  Active slots   : ${CYN}${SLOTS_ACTIVE_POST:-n/a}${RST}"
echo -e "  Idle slots     : ${CYN}${SLOTS_IDLE_POST:-n/a}${RST}"
[[ -n "$KV_DELTA" ]] && echo -e "  KV delta       : ${CYN}${KV_DELTA}${RST}"

# KV cache usage warning
if [[ "$KV_USAGE_POST" != "n/a" && "$KV_USAGE_POST" != "" ]]; then
    KV_PCT=$(awk "BEGIN {printf \"%.1f\", $KV_USAGE_POST * 100}")
    if awk "BEGIN {exit !($KV_USAGE_POST > 0.95)}"; then
        echo -e "\n  ${RED}⚠  KV cache at ${KV_PCT}% — near capacity, expect cache evictions${RST}"
    elif awk "BEGIN {exit !($KV_USAGE_POST > 0.80)}"; then
        echo -e "\n  ${YLW}⚠  KV cache at ${KV_PCT}% — getting full${RST}"
    else
        echo -e "\n  ${GRN}✓  KV cache at ${KV_PCT}% — healthy${RST}"
    fi
fi

echo ""
separator
echo -e "  ${BLD}Done.${RST} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
