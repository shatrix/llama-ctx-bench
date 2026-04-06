#!/usr/bin/env bash
# llama-ctx-bench.sh — Context load tester for llama.cpp router server
# Works with llama-server in router mode (--models-dir / --models-max).
# The router runs on the main port; each model spawns a child on a random port.
# Metrics and props are fetched from the child port when available (localhost only).
#
# Usage: ./llama-ctx-bench.sh -m <model> [options]
# Example: ./llama-ctx-bench.sh -h 192.168.2.180 -p 9090 -m Qwopus3.5-9B-v3 -c 64000

set -euo pipefail

# ── defaults ─────────────────────────────────────────────────────────────────
HOST="localhost"
PORT="8080"
MODEL=""
CTX_TARGET=32000
MAX_GEN_TOKENS=10
REQUEST_TIMEOUT=600
CHAR_TO_TOKEN_RATIO=4.5

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

# ── helpers ───────────────────────────────────────────────────────────────────
usage() {
    local exit_code=${1:-0}
    cat <<EOF
Usage: $0 -m <model_name> [options]

Required:
  -m MODEL      Model name as registered in llama-server router

Options:
  -h HOST       Server host (default: localhost)
  -p PORT       Router port (default: 8080)
  -c TOKENS     Target context tokens to fill (default: 32000)
  -t TIMEOUT    Request timeout seconds (default: 600)
  -r RATIO      Character-to-token ratio (default: 4.5)
  --help        Show this help

Notes:
  - Runs against a llama-server router instance
  - Model metrics are read from the child instance port via /models
  - Remote metric endpoints (props/metrics) require SSH access to server host
    and are skipped automatically when running against a remote server

Examples:
  $0 -m Qwopus3.5-9B-v3 -c 64000
  $0 -h 192.168.1.10 -p 9090 -m Nemotron-30B-Q4 -c 64000
EOF
    exit "$exit_code"
}

is_positive_int() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]; }

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

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

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

# ── arg parsing ───────────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage
while [[ $# -gt 0 ]]; do
    case $1 in
        -h) [[ $# -lt 2 ]] && { echo -e "${RED}Error: -h requires a value${RST}"; usage 1; }
            HOST="$2"; shift 2 ;;
        -p) [[ $# -lt 2 ]] && { echo -e "${RED}Error: -p requires a value${RST}"; usage 1; }
            is_positive_int "$2" || { echo -e "${RED}Error: -p must be a positive integer${RST}"; usage 1; }
            PORT="$2"; shift 2 ;;
        -m) [[ $# -lt 2 ]] && { echo -e "${RED}Error: -m requires a value${RST}"; usage 1; }
            MODEL="$2"; shift 2 ;;
        -c) [[ $# -lt 2 ]] && { echo -e "${RED}Error: -c requires a value${RST}"; usage 1; }
            is_positive_int "$2" || { echo -e "${RED}Error: -c must be a positive integer${RST}"; usage 1; }
            CTX_TARGET="$2"; shift 2 ;;
        -t) [[ $# -lt 2 ]] && { echo -e "${RED}Error: -t requires a value${RST}"; usage 1; }
            is_positive_int "$2" || { echo -e "${RED}Error: -t must be a positive integer${RST}"; usage 1; }
            REQUEST_TIMEOUT="$2"; shift 2 ;;
        -r) [[ $# -lt 2 ]] && { echo -e "${RED}Error: -r requires a value${RST}"; usage 1; }
            [[ "$2" =~ ^[0-9]+\.?[0-9]*$ ]] || { echo -e "${RED}Error: -r must be a positive number${RST}"; usage 1; }
            CHAR_TO_TOKEN_RATIO="$2"; shift 2 ;;
        --help) usage ;;
        *) echo -e "${RED}Unknown option: $1${RST}"; usage 1 ;;
    esac
done

[[ -z "$MODEL" ]] && { echo -e "${RED}Error: model name is required (-m)${RST}"; usage 1; }

BASE_URL="http://${HOST}:${PORT}"
IS_LOCAL=false
[[ "$HOST" == "localhost" || "$HOST" == "127.0.0.1" || "$HOST" == "::1" ]] && IS_LOCAL=true

check_deps

# ── banner ────────────────────────────────────────────────────────────────────
echo -e "\n${BLD}╔══════════════════════════════════════════════╗"
echo -e "║     llama-ctx-bench  —  Context load test    ║"
echo -e "╚══════════════════════════════════════════════╝${RST}"
echo -e "  Router  : ${CYN}${BASE_URL}${RST}"
echo -e "  Model   : ${CYN}${MODEL}${RST}"
echo -e "  Target  : ${CYN}${CTX_TARGET} tokens${RST}"
echo -e "  Time    : $(date '+%Y-%m-%d %H:%M:%S')"

# ── 1. router health ──────────────────────────────────────────────────────────
header "1 / 4  Router health & model status"

# Use native /models for rich metadata (discovery)
MODELS_JSON=$(curl -sf --max-time 10 "${BASE_URL}/models" 2>/dev/null || \
              curl -sf --max-time 10 "${BASE_URL}/v1/models" 2>/dev/null || \
              echo '{"data":[]}')

# Check for model entry
MODEL_ENTRY=$(echo "$MODELS_JSON" | jq -r --arg m "$MODEL" '.data[]? | select(.id == $m)' 2>/dev/null || echo "")

if [[ -z "$MODEL_ENTRY" ]]; then
    # health check fallback
    HEALTH=$(curl -sf --max-time 10 "${BASE_URL}/health" 2>/dev/null || echo '{"status":"unreachable"}')
    STATUS=$(echo "$HEALTH" | jq -r '.status // "unknown"')
    if [[ "$STATUS" != "ok" ]]; then
        echo -e "  Status : ${RED}${STATUS} — server not reachable, aborting${RST}"
        exit 1
    fi
    echo -e "  Model status  : ${RED}not found in models list${RST}"
    AVAILABLE_MODELS=$(echo "$MODELS_JSON" | jq -r '.data[].id' 2>/dev/null | sort | sed 's/^/    - /' || echo "    (none)")
    echo -e "  Available models:\n${CYN}${AVAILABLE_MODELS}${RST}"
    exit 1
fi

# Multi-model discovery based on 'args' presence
IS_ROUTER=false
if echo "$MODEL_ENTRY" | jq -e '.status.args? | type == "array" and length > 0' >/dev/null 2>&1; then
    IS_ROUTER=true
    echo -e "  Router status : ${GRN}ok (router mode)${RST}"
else
    echo -e "  Router status : ${GRN}ok (direct server mode)${RST}"
fi

MODEL_STATUS=$(echo "$MODEL_ENTRY" | jq -r '.status.value // "unknown"')
CHILD_PORT=$(echo "$MODEL_ENTRY" | jq -r '
  .status.args // [] | 
  . as $args | 
  ($args | to_entries | map(select(.value == "--port")) | .[0].key // -1) as $idx | 
  if $idx >= 0 and ($idx + 1) < ($args | length) then $args[$idx + 1] else empty end
' 2>/dev/null)
[[ -z "$CHILD_PORT" || "$CHILD_PORT" == "null" ]] && CHILD_PORT=""

# loaded or sleeping (idle) are ready states
if [[ "$MODEL_STATUS" == "loaded" || "$MODEL_STATUS" == "sleeping" ]]; then
    echo -e "  Model status  : ${GRN}${MODEL_STATUS}${RST}"
else
    echo -e "  Model status  : ${YLW}${MODEL_STATUS} — will load on first request${RST}"
fi

[[ -n "$CHILD_PORT" ]] && echo -e "  Child port    : ${CYN}${CHILD_PORT}${RST}"

# Extra config from args
EXTRACT_ARG() {
    local arg="$1"
    local val=$(echo "$MODEL_ENTRY" | jq -r --arg a "$arg" '
      .status.args // [] | 
      . as $args | 
      ($args | to_entries | map(select(.value == $a)) | .[0].key // -1) as $idx | 
      if $idx >= 0 and ($idx + 1) < ($args | length) then $args[$idx + 1] else empty end
    ' 2>/dev/null)
    [[ -z "$val" ]] && echo "n/a" || echo "$val"
}
B_SIZE=$(EXTRACT_ARG "--batch-size")
UB_SIZE=$(EXTRACT_ARG "--ubatch-size")
PARALLEL=$(EXTRACT_ARG "--parallel")
REUSE=$(EXTRACT_ARG "--cache-reuse")
RAM=$(EXTRACT_ARG "--cache-ram")
FLASH=$(EXTRACT_ARG "--flash-attn")
[[ -z "$FLASH" || "$FLASH" == "n/a" ]] && FLASH="off"

echo -e "  Batch config  : ${CYN}batch ${B_SIZE}, ubatch ${UB_SIZE}, parallel ${PARALLEL}${RST}"
echo -e "  Cache config  : ${CYN}reuse ${REUSE}, ram ${RAM}${RST}"
echo -e "  Flash attention: ${CYN}${FLASH}${RST}"

# extract ctx-size from model args
MODEL_CTX=$(EXTRACT_ARG "--ctx-size")
echo -e "  Configured ctx: ${CYN}${MODEL_CTX} tokens${RST}"

# early validation
if [[ "$MODEL_CTX" =~ ^[0-9]+$ ]] && (( CTX_TARGET > MODEL_CTX )); then
    echo -e "\n  ${RED}Error: Target context (${CTX_TARGET}) exceeds model max (${MODEL_CTX})${RST}"
    echo -e "  Either reduce -c value or increase model --ctx-size"
    exit 1
fi

# ── 2. child metrics (only if local and child port known) ─────────────────────
header "2 / 4  Pre-request metrics"

CHILD_METRICS_PRE=""
KV_USAGE_PRE=""; KV_TOKENS_PRE=""

if [[ "$IS_LOCAL" == true && -n "$CHILD_PORT" ]]; then
    CHILD_METRICS_PRE=$(curl -sf --max-time 5 "http://127.0.0.1:${CHILD_PORT}/metrics" 2>/dev/null || echo "")
    if [[ -n "$CHILD_METRICS_PRE" ]]; then
        # Use standardized grep -m 1 -E for compatibility
        KV_USAGE_PRE=$(echo "$CHILD_METRICS_PRE" | grep -m 1 -E 'llamacpp[:_]kv_cache_usage_ratio' | awk '{print $NF}' || echo "")
        KV_TOKENS_PRE=$(echo "$CHILD_METRICS_PRE" | grep -m 1 -E 'llamacpp[:_]kv_cache_tokens' | awk '{print $NF}' || echo "")
        SLOTS_ACTIVE=$(echo "$CHILD_METRICS_PRE" | grep -m 1 -E 'llamacpp[:_]slots_active' | awk '{print $NF}' || echo "")

        [[ -n "$KV_USAGE_PRE" ]] && echo -e "  KV cache usage : ${CYN}${KV_USAGE_PRE}${RST}"
        [[ -n "$KV_TOKENS_PRE" ]] && echo -e "  KV cache tokens: ${CYN}${KV_TOKENS_PRE}${RST}"
        [[ -n "$SLOTS_ACTIVE" ]] && echo -e "  Active slots   : ${CYN}${SLOTS_ACTIVE}${RST}"

        if [[ -z "$KV_USAGE_PRE" && -z "$KV_TOKENS_PRE" ]]; then
            echo -e "  ${YLW}Note: Standard KV metrics not found in child instance response${RST}"
        fi
    else
        echo -e "  ${YLW}Child metrics unavailable on port ${CHILD_PORT}${RST}"
    fi
else
    if [[ "$IS_LOCAL" == false ]]; then
        echo -e "  ${YLW}Skipping child metrics — remote server (child ports are localhost-only)${RST}"
    else
        echo -e "  ${YLW}Model not active — child port not assigned yet${RST}"
    fi
fi

# ── 3. send request ───────────────────────────────────────────────────────────
header "3 / 4  Context-fill request"

REPEAT_UNIT="The quick brown fox jumps over the lazy dog. "
UNIT_LEN=${#REPEAT_UNIT}

# Handle safety margin
SAFE_TARGET=$CTX_TARGET
if [[ "$MODEL_CTX" =~ ^[0-9]+$ ]] && (( CTX_TARGET + 1024 > MODEL_CTX )); then
    SAFE_TARGET=$(( MODEL_CTX - 1024 ))
    echo -e "  ${YLW}[WARN] Capping filler to ${SAFE_TARGET} tokens (leaving 1k buffer)${RST}"
fi

# Multiplier: chars per token (use Python for safe large-number arithmetic)
CHARS_NEEDED=$(python3 -c "print(int($SAFE_TARGET * $CHAR_TO_TOKEN_RATIO))")
REPEATS=$(( CHARS_NEEDED / UNIT_LEN ))

echo -e "  Filler size    : ${REPEATS} repetitions (~${CHARS_NEEDED} chars)"
echo -e "  Using ratio    : ${CHAR_TO_TOKEN_RATIO} chars/token"

PAYLOAD_FILE=$(mktemp /tmp/llama-ctx-bench-XXXXXX.json)
chmod 600 "$PAYLOAD_FILE"
trap 'rm -f "$PAYLOAD_FILE"' EXIT

python3 -c "
import json
payload = {
    'model':    '$MODEL',
    'messages': [{'role': 'user', 'content': 'The quick brown fox jumps over the lazy dog. ' * $REPEATS}],
    'max_tokens': $MAX_GEN_TOKENS,
    'temperature': 0,
    'stream': False
}
with open('$PAYLOAD_FILE', 'w') as fh:
    json.dump(payload, fh)
"

echo -ne "  Sending request (timeout: ${REQUEST_TIMEOUT}s)"
START_TS=$(now_ms)

RESPONSE_FILE=$(mktemp)
STATUS_FILE=$(mktemp)
# run curl in background for progress indicator
(curl -s -w "%{http_code}" -o "$RESPONSE_FILE" \
    --max-time "$REQUEST_TIMEOUT" \
    -X POST "${BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "@${PAYLOAD_FILE}" > "$STATUS_FILE" 2>/dev/null) &
CURL_PID=$!

# progress indicator (use stderr for unbuffered output)
while kill -0 $CURL_PID 2>/dev/null; do
    sleep 10
    kill -0 $CURL_PID 2>/dev/null && printf "." >&2
done
wait $CURL_PID
HTTP_STATUS=$(cat "$STATUS_FILE")
RESPONSE=$(cat "$RESPONSE_FILE")
rm -f "$RESPONSE_FILE" "$STATUS_FILE"

[[ -z "$HTTP_STATUS" || "$HTTP_STATUS" == "000" ]] && HTTP_STATUS="000"

END_TS=$(now_ms)
WALL_MS=$(( END_TS - START_TS ))

# ── 4. results ────────────────────────────────────────────────────────────────
header "4 / 4  Results"

if [[ "$HTTP_STATUS" != "200" ]]; then
    echo -e "  ${RED}Request failed — HTTP ${HTTP_STATUS}${RST}"
    ERROR_MSG=$(echo "$RESPONSE" | jq -r 'if .error then .error.message // . else . // "no error field" end' 2>/dev/null || echo "unparseable response")
    echo -e "  Server response: ${ERROR_MSG}"
    exit 1
fi

PROMPT_TOKENS=$(echo "$RESPONSE" | jq -r '.usage.prompt_tokens // 0')
CACHED_TOKENS=$(echo "$RESPONSE" | jq -r '.usage.prompt_tokens_details.cached_tokens // 0')
FRESH_TOKENS=$(awk "BEGIN {printf \"%.0f\", $PROMPT_TOKENS - $CACHED_TOKENS}")
COMPL_TOKENS=$(echo  "$RESPONSE" | jq -r '.usage.completion_tokens // 0')

TIMINGS=$(echo "$RESPONSE" | jq '.timings? // {}')
T_PROMPT_MS=$(echo "$TIMINGS" | jq -r '.prompt_ms // 0')
T_PREDICT_MS=$(echo "$TIMINGS"| jq -r '.predicted_ms // 0')
PROMPT_TPS=$(echo "$TIMINGS"  | jq -r '.prompt_per_second // 0')
PREDICT_TPS=$(echo "$TIMINGS" | jq -r '.predicted_per_second // 0')

echo -e "  ${BLD}── Token counts ──────────────────────────────${RST}"
echo -e "  Prompt tokens   : ${CYN}${PROMPT_TOKENS}${RST}"
if [[ "$CACHED_TOKENS" -gt 0 ]]; then
    echo -e "  Cached tokens   : ${CYN}${CACHED_TOKENS}${RST}  (cache hit)"
else
    echo -e "  Cached tokens   : ${CYN}0${RST}  (cold run)"
fi
echo -e "  Fresh processed : ${CYN}${FRESH_TOKENS}${RST}"
echo -e "  Generated tokens: ${CYN}${COMPL_TOKENS}${RST}"

echo -e "\n  ${BLD}── Timings ───────────────────────────────────${RST}"
echo -e "  Wall clock total: ${CYN}$(fmt_ms $WALL_MS)${RST}"
if [[ "$T_PROMPT_MS" != "0" ]]; then
    echo -e "  Prefill time    : ${CYN}$(fmt_ms $(echo "$T_PROMPT_MS" | awk '{printf "%.2f", $1}'))${RST}"
    echo -e "  Generate time   : ${CYN}$(fmt_ms $(echo "$T_PREDICT_MS" | awk '{printf "%.2f", $1}'))${RST}"
    echo -e "  Prefill speed   : ${CYN}$(printf '%.1f' $PROMPT_TPS) t/s${RST}"
    echo -e "  Generate speed  : ${CYN}$(printf '%.1f' $PREDICT_TPS) t/s${RST}"
fi

if [[ "$IS_LOCAL" == true ]]; then
    # Refresh child port for metrics (model may have just spawned)
    MODELS_JSON2=$(curl -sf --max-time 10 "${BASE_URL}/models" 2>/dev/null || echo '{"data":[]}')
    NEW_PORT=$(echo "$MODELS_JSON2" | jq -r --arg m "$MODEL" '
      .data[]? | select(.id == $m) | 
      (.status.args // []) | 
      . as $args | 
      ($args | to_entries | map(select(.value == "--port")) | .[0].key // -1) as $idx | 
      if $idx >= 0 and ($idx + 1) < ($args | length) then $args[$idx + 1] else empty end
    ' 2>/dev/null)
    [[ -z "$NEW_PORT" ]] && NEW_PORT="$CHILD_PORT"
    
    if [[ -n "$NEW_PORT" ]]; then
        CHILD_METRICS_POST=$(curl -sf --max-time 5 "http://127.0.0.1:${NEW_PORT}/metrics" 2>/dev/null || echo "")
        KV_TOKENS_POST=$(echo "$CHILD_METRICS_POST" | grep -m 1 -E 'llamacpp[:_]kv_cache_tokens' | awk '{print $NF}' || echo "")
        KV_USAGE_POST=$(echo "$CHILD_METRICS_POST" | grep -m 1 -E 'llamacpp[:_]kv_cache_usage_ratio' | awk '{print $NF}' || echo "")

        if [[ -n "$KV_TOKENS_POST" && "$KV_TOKENS_POST" =~ ^[0-9.]+$ ]]; then
            echo -e "\n  ${BLD}── KV cache (post-request) ───────────────────${RST}"
            echo -e "  KV cache tokens: ${CYN}${KV_TOKENS_POST}${RST}"
            if [[ -n "$KV_TOKENS_PRE" && "$KV_TOKENS_PRE" =~ ^[0-9.]+$ ]]; then
                KV_DELTA=$(awk "BEGIN {printf "%.0f", $KV_TOKENS_POST - $KV_TOKENS_PRE}")
                if [[ "$KV_DELTA" -ge 0 ]]; then
                    echo -e "  KV delta       : ${CYN}${KV_DELTA} tokens added${RST}"
                else
                    echo -e "  KV delta       : ${CYN}${KV_DELTA}${RST} (cache cleared)"
                fi
            fi
            if [[ -n "$KV_USAGE_POST" && "$KV_USAGE_POST" =~ ^[0-9.]+$ ]]; then
                KV_PCT=$(awk "BEGIN {printf "%.1f", $KV_USAGE_POST * 100}")
                echo -e "  KV usage       : ${CYN}${KV_PCT}%${RST}"
            fi
        fi
    fi
else
    echo -e "\n  ${YLW}Note: KV cache metrics unavailable for remote servers.${RST}"
    echo -e "  Run nvidia-smi on the server host for VRAM details.${RST}"
fi

separator
echo -e "  ${BLD}Done.${RST} Total: $(fmt_ms $WALL_MS) | $(date '+%Y-%m-%d %H:%M:%S')"
