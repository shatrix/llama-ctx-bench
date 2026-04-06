# llama-ctx-bench

A bash script for testing llama.cpp server's context handling under load. It sends context-fill requests of configurable size and reports timing, token usage, and server-side KV cache metrics.

## Requirements

- **curl** - for HTTP requests
- **jq** - for JSON parsing
- **bc** - for floating-point arithmetic
- **python3** - for timestamp generation and string manipulation

Install on Debian/Ubuntu:
```
sudo apt install curl jq bc python3
```

The script runs from any machine. It connects to a llama.cpp server over HTTP, so no GPU or llama.cpp installation is needed on the client side.

## Usage

```
./llama-ctx-bench.sh -m <model_name> [options]
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-m MODEL` | Model name as registered in llama-server | (required) |
| `-h HOST` | Server hostname or IP | localhost |
| `-p PORT` | Server port | 8080 |
| `-c TOKENS` | Target context size in tokens | 32000 |
| `-t TIMEOUT` | Request timeout in seconds | 600 |
| `--help` | Show usage help | - |

### Examples

Test locally with default settings:
```
./llama-ctx-bench.sh -m my-model
```

Test against a remote server with 64k context:
```
./llama-ctx-bench.sh -h 192.168.1.100 -p 8080 -m Llama-3.1-70B-Q4 -c 64000
```

Test with short timeout:
```
./llama-ctx-bench.sh -m large-model -c 128000 -t 300
```

## What It Does

The script performs a 5-step test:

1. **Server health check** - Verifies the server responds to `/health`
2. **Model info** - Fetches server properties (`/props`) including n_ctx and slot configuration
3. **Pre-request metrics** - Captures KV cache state before the request (`/metrics`)
4. **Context-fill request** - Sends a large prompt to fill the target context size
5. **Results** - Reports token counts, timings, and post-request server metrics

### The Request

The script generates a repetitive text prompt ("The quick brown fox...") scaled to approximately fill the target token count. It uses the chat completions API with:
- `max_tokens: 10` - Only generates 10 tokens to isolate prefill timing
- `temperature: 0` - Deterministic output
- `stream: false` - Single response

## Output Explained

### Token Counts

| Field | Description |
|-------|-------------|
| Prompt tokens | Tokens in the input prompt |
| Cached tokens | Tokens recovered from KV cache (second run will show higher cached count) |
| Fresh tokens | Tokens that required fresh computation (prompt - cached) |
| Generated tokens | Tokens produced by the model |

### Timings

| Field | Description |
|-------|-------------|
| Wall clock total | End-to-end request time including network latency |
| Prefill time | Time spent processing the input prompt (from server timings) |
| Generate time | Time spent generating output tokens |
| Prefill/Generate speed | Tokens per second for each phase |

Server-side timings are only available if the llama.cpp server exposes them in the response.

### Server Metrics

These come from the server's `/metrics` endpoint (Prometheus format):

| Metric | Description |
|--------|-------------|
| KV cache usage | Ratio of KV cache currently in use (0.0 to 1.0) |
| KV cache tokens | Absolute number of tokens held in KV cache |
| Active/idle slots | Number of context slots currently in use or available |
| KV delta | Change in KV cache token count since the request |

### Warnings

The script prints warnings when:
- KV cache usage exceeds 80% (cache getting full)
- KV cache usage exceeds 95% (near capacity, expect evictions)

## Limitations

### Metrics Source

KV cache and slot metrics come from the llama.cpp server's `/metrics` endpoint. If the server does not expose these metrics, the corresponding fields will show as unavailable.

This script does not measure raw GPU VRAM (used/free/total). For NVIDIA-specific GPU memory details, run `nvidia-smi` directly on the server.

### Multi-GPU

On multi-GPU setups, KV cache metrics reflect total usage across all GPUs. There is no per-GPU breakdown.

### Caching Behavior

Running the script twice against the same server will show different cached token counts on the second run. The first run is a cold measurement. Clear the server context or restart the server to get consistent cold measurements.

### Network Latency

Wall clock time includes network round-trip latency. Server-side prefill timing is more accurate for measuring compute performance, but it is only available if the server includes timing data in its response.

## Architecture

```
Client (this script)                    Server (llama.cpp)
      |                                      |
      |-- GET /health ---------------------->|
      |<-- health status --------------------|
      |                                      |
      |-- GET /props ------------------------>|
      |<-- model configuration ---------------|
      |                                      |
      |-- GET /metrics ---------------------->|
      |<-- pre-request KV cache state --------|
      |                                      |
      |-- POST /v1/chat/completions --------->|
      |    (large context-fill prompt)        |
      |<-- response + token usage ------------|
      |                                      |
      |-- GET /metrics ---------------------->|
      |<-- post-request KV cache state -------|
```

## Exit Codes

- `0` - Success
- `1` - Error (server unhealthy, request failed, missing dependencies, invalid arguments)
