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
  --help        Show this help

Notes:
  - Runs against a llama-server router instance
  - Model metrics are read from the child instance port via /v1/models
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
        --help) usage ;;
        *) echo -e "${RED}Unknown option: $1${RST}"; usage 1 ;;
    esac
done

[[ -z "$MODEL" ]] && { echo -e "${RED}Error: model name is required (-m)${RST}"; usage 1; }

BASE_URL="http://${HOST}:${PORT}"
IS_LOCAL=false
[[ "$HOST" == "localhost" || "$HOST" == "127.0.0.1" ]] && IS_LOCAL=true

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

MODELS_JSON=$(curl -sf --max-time 10 "${BASE_URL}/v1/models" 2>/dev/null || echo '{}')

# check router is alive
ROUTER_ROLE=$(echo "$MODELS_JSON" | jq -r '.role? // "unknown"' 2>/dev/null || echo "unknown")
if [[ "$ROUTER_ROLE" == "router" ]]; then
    echo -e "  Router status : ${GRN}ok (router mode)${RST}"
else
    # might be a direct server, check /health
    HEALTH=$(curl -sf --max-time 10 "${BASE_URL}/health" 2>/dev/null || echo '{"status":"unreachable"}')
    STATUS=$(echo "$HEALTH" | jq -r '.status // "unknown"')
    if [[ "$STATUS" != "ok" ]]; then
        echo -e "  Status : ${RED}${STATUS} — server not reachable, aborting${RST}"
        exit 1
    fi
    echo -e "  Router status : ${GRN}ok (direct server mode)${RST}"
fi

# find model in list
MODEL_ENTRY=$(echo "$MODELS_JSON" | jq -r --arg m "$MODEL" '.data[]? | select(.id == $m)' 2>/dev/null || echo "")

if [[ -z "$MODEL_ENTRY" ]]; then
    echo -e "  Model status  : ${RED}not found in /v1/models${RST}"
    AVAILABLE_MODELS=$(echo "$MODELS_JSON" | jq -r '.data[].id' 2>/dev/null | sort | sed 's/^/    - /' || echo "    (none)")
    echo -e "  Available models:\n${CYN}${AVAILABLE_MODELS}${RST}"
    echo -e "  ${RED}Aborting.${RST}"
    exit 1
else
    MODEL_STATUS=$(echo "$MODEL_ENTRY" | jq -r '.status.value // "unknown"')
    CHILD_PORT=$(echo "$MODEL_ENTRY" | jq -r '.status.args[]?' 2>/dev/null | \
        grep -A1 '^--port$' | tail -1 || echo "0")
    # port 0 means unloaded/not assigned
    [[ "$CHILD_PORT" == "0" ]] && CHILD_PORT=""

    if [[ "$MODEL_STATUS" == "loaded" ]]; then
        echo -e "  Model status  : ${GRN}loaded${RST}"
    else
        echo -e "  Model status  : ${YLW}${MODEL_STATUS} — will load on first request (adds load time)${RST}"
    fi
    [[ -n "$CHILD_PORT" ]] && echo -e "  Child port    : ${CYN}${CHILD_PORT}${RST}"

    # Extract extra config from args
    EXTRACT_ARG() { echo "$MODEL_ENTRY" | jq -r --arg a "$1" '.status.args[]?' 2>/dev/null | grep -A1 "^$1$" | tail -1 || echo "n/a"; }
    B_SIZE=$(EXTRACT_ARG "--batch-size")
    UB_SIZE=$(EXTRACT_ARG "--ubatch-size")
    PARALLEL=$(EXTRACT_ARG "--parallel")
    FLASH=$(echo "$MODEL_ENTRY" | jq -r '.status.args[]?' 2>/dev/null | grep -A1 '^--flash-attn$' | tail -1 || echo "off")

    echo -e "  Batch config  : ${CYN}batch ${B_SIZE}, ubatch ${UB_SIZE}, parallel ${PARALLEL}${RST}"
    echo -e "  Flash attention: ${CYN}${FLASH}${RST}"
fi

# extract ctx-size from model args
MODEL_CTX=$(echo "$MODEL_ENTRY" | jq -r '.status.args[]?' 2>/dev/null | \
    grep -A1 '^--ctx-size$' | tail -1 || echo "n/a")
echo -e "  Configured ctx: ${CYN}${MODEL_CTX} tokens${RST}"

# (Context overflow checks now happen in section 3)

# ── 2. child metrics (only if local and child port known) ─────────────────────
header "2 / 4  Pre-request metrics"

CHILD_METRICS_PRE=""
KV_USAGE_PRE="n/a"; KV_TOKENS_PRE="n/a"

if [[ "$IS_LOCAL" == true && -n "$CHILD_PORT" ]]; then
    CHILD_METRICS_PRE=$(curl -sf --max-time 5 "http://127.0.0.1:${CHILD_PORT}/metrics" 2>/dev/null || echo "")
    if [[ -n "$CHILD_METRICS_PRE" ]]; then
        KV_USAGE_PRE=$(echo "$CHILD_METRICS_PRE" | grep -m1 'llamacpp:kv_cache_usage_ratio' | awk '{print $2}' || echo "n/a")
        KV_TOKENS_PRE=$(echo "$CHILD_METRICS_PRE" | grep -m1 'llamacpp:kv_cache_tokens' | awk '{print $2}' || echo "n/a")
        SLOTS_ACTIVE=$(echo "$CHILD_METRICS_PRE" | grep -m1 'llamacpp:slots_active' | awk '{print $2}' || echo "n/a")
        echo -e "  KV cache usage : ${CYN}${KV_USAGE_PRE}${RST}"
        echo -e "  KV cache tokens: ${CYN}${KV_TOKENS_PRE}${RST}"
        echo -e "  Active slots   : ${CYN}${SLOTS_ACTIVE}${RST}"
    else
        echo -e "  ${YLW}Child metrics unavailable on port ${CHILD_PORT}${RST}"
    fi
else
    if [[ "$IS_LOCAL" == false ]]; then
        echo -e "  ${YLW}Skipping child metrics — remote server (child ports are localhost-only)${RST}"
    else
        echo -e "  ${YLW}Model not loaded yet — no child port available${RST}"
    fi
fi

# ── 3. send request ───────────────────────────────────────────────────────────
header "3 / 4  Context-fill request"

REPEAT_UNIT="The quick brown fox jumps over the lazy dog. "
UNIT_LEN=${#REPEAT_UNIT}

# Handle safety margin relative to model's context limit
SAFE_TARGET=$CTX_TARGET
if [[ "$MODEL_CTX" != "n/a" ]] && is_positive_int "$MODEL_CTX"; then
    # if target + overhead (estimated ~2k) exceeds context, cap it
    if (( CTX_TARGET + 1024 > MODEL_CTX )); then
        SAFE_TARGET=$(( MODEL_CTX - 1024 ))
        echo -e "  ${YLW}⚠  Capping filler to ${SAFE_TARGET} tokens (leaving 1k buffer for overhead)${RST}"
    fi
fi

# Multiplier: 4.5 chars/token is highly accurate for this specific string and BPE
CHARS_NEEDED=$(( SAFE_TARGET * 45 / 10 ))
REPEATS=$(( CHARS_NEEDED / UNIT_LEN ))

echo -e "  Filler size    : ${REPEATS} repetitions (~${CHARS_NEEDED} chars)"

# Build payload in python3 → temp file to avoid shell arg length limits
PAYLOAD_FILE=$(mktemp /tmp/llama-ctx-bench-XXXXXX.json)
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

echo -e "  Sending request (timeout: ${REQUEST_TIMEOUT}s)..."
echo -e "  ${YLW}Note: if model was unloaded, add ~30-60s for load time${RST}"

START_TS=$(now_ms)

# Use -w to get HTTP status code separately, don't use -f so we see error bodies
HTTP_RESPONSE=$(curl -s -w "\n__HTTP_STATUS__%{http_code}" \
    --max-time "$REQUEST_TIMEOUT" \
    -X POST "${BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "@${PAYLOAD_FILE}" 2>/dev/null || echo '{"error":"curl_failed"}\n__HTTP_STATUS__000')

END_TS=$(now_ms)
WALL_MS=$(( END_TS - START_TS ))

# split body and status code
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | grep '__HTTP_STATUS__' | sed 's/__HTTP_STATUS__//')
RESPONSE=$(echo "$HTTP_RESPONSE" | grep -v '__HTTP_STATUS__')

# ── 4. results ────────────────────────────────────────────────────────────────
header "4 / 4  Results"

if [[ "$HTTP_STATUS" != "200" ]]; then
    echo -e "  ${RED}Request failed — HTTP ${HTTP_STATUS}${RST}"
    echo -e "  Server response: $(echo "$RESPONSE" | jq -r '.error.message? // .' 2>/dev/null | head -3)"
    echo ""
    echo -e "  Wall clock: ${CYN}$(fmt_ms $WALL_MS)${RST}"
    exit 1
fi

# token counts
PROMPT_TOKENS=$(echo "$RESPONSE" | jq -r '.usage.prompt_tokens // 0')
COMPL_TOKENS=$(echo  "$RESPONSE" | jq -r '.usage.completion_tokens // 0')
TOTAL_TOKENS=$(echo  "$RESPONSE" | jq -r '.usage.total_tokens // 0')
CACHED_TOKENS=$(echo "$RESPONSE" | jq -r '.usage.prompt_tokens_details.cached_tokens // 0')
FRESH_TOKENS=$(awk "BEGIN {printf \"%.0f\", $PROMPT_TOKENS - $CACHED_TOKENS}")

# timings from response body
TIMINGS=$(echo "$RESPONSE" | jq '.timings? // {}')
T_PROMPT_MS=$(echo "$TIMINGS" | jq -r '.prompt_ms // 0')
T_PREDICT_MS=$(echo "$TIMINGS"| jq -r '.predict_ms // 0')
PROMPT_TPS=$(echo "$TIMINGS"  | jq -r '.prompt_per_second // 0')
PREDICT_TPS=$(echo "$TIMINGS" | jq -r '.predicted_per_second // 0')

echo ""
echo -e "  ${BLD}── Token counts ──────────────────────────────${RST}"
echo -e "  Prompt tokens   : ${CYN}${PROMPT_TOKENS}${RST}"
CACHE_NOTE=$(awk "BEGIN {print ($CACHED_TOKENS > 0) ? \"(cache hit — cold result needs a fresh run)\" : \"(cold run)\"}")
echo -e "  Cached tokens   : ${CYN}${CACHED_TOKENS}${RST}  ${CACHE_NOTE}"
echo -e "  Fresh processed : ${CYN}${FRESH_TOKENS}${RST}"
echo -e "  Generated tokens: ${CYN}${COMPL_TOKENS}${RST}"
echo -e "  Total tokens    : ${CYN}${TOTAL_TOKENS}${RST}"

echo ""
echo -e "  ${BLD}── Timings ───────────────────────────────────${RST}"
echo -e "  Wall clock total: ${CYN}$(fmt_ms $WALL_MS)${RST}"
if [[ "$T_PROMPT_MS" != "0" ]]; then
    echo -e "  Prefill time    : ${CYN}$(fmt_ms $(echo "$T_PROMPT_MS" | awk '{printf "%.2f", $1}'))${RST}"
    echo -e "  Generate time   : ${CYN}$(fmt_ms $(echo "$T_PREDICT_MS" | awk '{printf "%.2f", $1}'))${RST}"
    echo -e "  Prefill speed   : ${CYN}$(printf '%.1f' $PROMPT_TPS) t/s${RST}"
    echo -e "  Generate speed  : ${CYN}$(printf '%.1f' $PREDICT_TPS) t/s${RST}"
else
    echo -e "  (server did not return per-request timings)"
fi

# post-request child metrics (local only)
if [[ "$IS_LOCAL" == true ]]; then
    # re-query models to get child port if model just loaded
    if [[ -z "$CHILD_PORT" ]]; then
        MODELS_JSON2=$(curl -sf --max-time 10 "${BASE_URL}/v1/models" 2>/dev/null || echo '{}')
        CHILD_PORT=$(echo "$MODELS_JSON2" | jq -r --arg m "$MODEL" \
            '.data[]? | select(.id == $m) | .status.args[]?' 2>/dev/null | \
            grep -A1 '^--port$' | tail -1 || echo "0")
        [[ "$CHILD_PORT" == "0" ]] && CHILD_PORT=""
    fi

    if [[ -n "$CHILD_PORT" ]]; then
        CHILD_METRICS_POST=$(curl -sf --max-time 5 "http://127.0.0.1:${CHILD_PORT}/metrics" 2>/dev/null || echo "")
        if [[ -n "$CHILD_METRICS_POST" ]]; then
            KV_USAGE_POST=$(echo "$CHILD_METRICS_POST" | grep -m1 'llamacpp:kv_cache_usage_ratio' | awk '{print $2}' || echo "n/a")
            KV_TOKENS_POST=$(echo "$CHILD_METRICS_POST" | grep -m1 'llamacpp:kv_cache_tokens' | awk '{print $2}' || echo "n/a")

            echo ""
            echo -e "  ${BLD}── KV cache (post-request) ───────────────────${RST}"
            echo -e "  KV cache tokens: ${CYN}${KV_TOKENS_POST}${RST}"

            if [[ "$KV_TOKENS_PRE" != "n/a" && "$KV_TOKENS_POST" != "n/a" ]]; then
                KV_DELTA=$(awk "BEGIN {printf \"%.0f\", $KV_TOKENS_POST - $KV_TOKENS_PRE}")
                echo -e "  KV delta       : ${CYN}${KV_DELTA} tokens added${RST}"
            fi

            if [[ "$KV_USAGE_POST" != "n/a" && "$KV_USAGE_POST" != "" ]]; then
                KV_PCT=$(awk "BEGIN {printf \"%.1f\", $KV_USAGE_POST * 100}")
                if awk "BEGIN {exit !($KV_USAGE_POST > 0.95)}"; then
                    echo -e "\n  ${RED}⚠  KV cache at ${KV_PCT}% — near capacity${RST}"
                elif awk "BEGIN {exit !($KV_USAGE_POST > 0.80)}"; then
                    echo -e "\n  ${YLW}⚠  KV cache at ${KV_PCT}% — getting full${RST}"
                else
                    echo -e "\n  ${GRN}✓  KV cache at ${KV_PCT}% — healthy${RST}"
                fi
            fi
        fi
    fi
else
    echo ""
    echo -e "  ${YLW}Note: KV cache metrics unavailable for remote servers.${RST}"
    echo -e "  ${YLW}Run nvidia-smi on the server host for VRAM details.${RST}"
fi

echo ""
separator
echo -e "  ${BLD}Done.${RST} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
