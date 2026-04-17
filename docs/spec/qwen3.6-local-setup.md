# Qwen3.6-35B-A3B local setup for `pi` coding agent

## Purpose

Run `unsloth/Qwen3.6-35B-A3B-GGUF` locally on Apple Silicon and wire it up as the backing model for the [`pi` coding agent](https://shittycodingagent.ai) (`@mariozechner/pi-coding-agent`).

## Key facts

- **Model is public** on HuggingFace — `HF_TOKEN` is not required.
- **Mixture-of-experts:** 35B total parameters, only 3B active per token → fast inference on Apple Silicon.
- Uses the `qwen3moe` architecture already supported by brew's `llama.cpp`.
- `pi` supports custom OpenAI-compatible providers via `~/.pi/agent/models.json`.
- `bun install -g` installs `pi` from the npm registry into `~/.bun/bin`.

## Why llama.cpp (and not llama-cpp-python, SGLang, vLLM, Ollama)

`llama.cpp`'s `llama-server` is the lowest-friction path on Apple Silicon:
- Metal-accelerated out of the box.
- OpenAI-compatible JSON API.
- Built-in HuggingFace downloader (`-hf` flag).
- Handles Jinja chat templates and reasoning-content splitting natively.

Alternatives considered:
- **`llama-cpp-python`** — lags upstream; fewer server features; weaker fit for bleeding-edge models.
- **Ollama** — wraps the same engine but hides tuning flags (KV quantization, reasoning-format) and lags on new Qwen quants.
- **LM Studio** — GUI-first; doesn't fit a CLI/agent workflow.
- **SGLang / vLLM** — designed for CUDA/data-center throughput; not the right tool for a local Mac + GGUF.

## Quantization: UD-Q5_K_XL (~26GB)

At 64K context on a 64GB M1 Ultra:
- KV cache runs ~6–8GB (F16) or ~3–4GB with Q8 KV.
- Q5_K_XL leaves ~28GB headroom for OS + apps.
- Q4_K_XL loses measurable coding quality per unsloth's benchmarks.
- Q6_K_XL (~31GB) fits but tightens under load.

## Architecture

```
┌──────────────┐   OpenAI-compatible    ┌───────────────┐
│      pi      │  ───── JSON ────────>  │ llama-server  │
│  (bun CLI)   │  http://localhost:8080 │  (brew/Metal) │
└──────────────┘                        └───────────────┘
                                               │
                                               ▼
                              ~/.cache/huggingface/hub/
                              models--unsloth--Qwen3.6-35B-A3B-GGUF/
                                      (26GB GGUF weights)
```

## `llama-server` flag rationale

```
llama-server \
  -hf unsloth/Qwen3.6-35B-A3B-GGUF:Q5_K_XL \
  --alias qwen3-local \
  -c 65536 \
  -fa on \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --jinja \
  --reasoning-format deepseek \
  --temp 0.6 --top-p 0.95 --top-k 20 \
  --host 127.0.0.1 --port 8080
```

- `-hf …:Q5_K_XL` — resolves quant tag against the HF repo; downloads to `~/.cache/huggingface/hub/models--unsloth--Qwen3.6-35B-A3B-GGUF/` on first run (standard HF hub layout: content-addressed `blobs/` + human-readable `snapshots/<commit>/*.gguf` symlinks). On subsequent runs, llama-server revalidates the `main` ref and reuses the local blob — no re-download. Fallback if the tag doesn't resolve: `--hf-file Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf`. Also pulls `mmproj-BF16.gguf` (~861MB) automatically because Qwen3.6 is multimodal.
- `--alias qwen3-local` — stable model id so `models.json` doesn't depend on the GGUF filename.
- `-c 65536` — 64K context window (model supports 262K natively if needed later).
- `-fa on` + `--cache-type-{k,v} q8_0` — Flash Attention + quantized KV cache roughly halves KV memory with negligible quality cost.
- `--jinja` — applies the model's official chat template.
- `--reasoning-format deepseek` — splits `<think>…</think>` into `reasoning_content` instead of `content`. `pi`'s `openai-completions` adapter ignores `reasoning_content`, so thinking tokens don't get fed back into context.
- Sampling params are unsloth's coding-mode recommendations (`temperature=0.6, top_p=0.95, top_k=20`).

## pi provider config

`just configure` installs two files:

- `config/models.json` → copied to `~/.pi/agent/models.json` (defines the `local-llm` provider). pi hot-reloads this file — no restart needed.
- `config/settings.json` → **merged** into `~/.pi/agent/settings.json` using `jq -s '.[0] * .[1]'` so pi's runtime-written fields (e.g. `lastChangelogVersion`) are preserved. The existing settings file is backed up to `~/.pi/agent/settings.json.bak.<ISO-timestamp>` before the merge, so reruns are non-destructive.

`config/settings.json` sets:
```json
{
  "defaultProvider": "local-llm",
  "defaultModel": "qwen3-local",
  "defaultThinkingLevel": "medium"
}
```
This makes bare `pi` default to the local server — no `--provider`/`--model` flags needed. `just pi` still passes them explicitly as defense-in-depth in case the settings merge wasn't run.

```json
{
  "providers": {
    "local-llm": {
      "baseUrl": "http://localhost:8080/v1",
      "api": "openai-completions",
      "apiKey": "dummy",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      },
      "models": [
        {
          "id": "qwen3-local",
          "name": "Qwen3.6-35B-A3B (local)",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 65536,
          "maxTokens": 8192,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
```

## Workflow

1. `just install` — brew installs `llama.cpp`, bun installs `pi`.
2. `just configure` — copies `config/models.json` into `~/.pi/agent/`.
3. `just serve` — foreground. First run downloads ~26GB to `~/.cache/huggingface/hub/`.
4. `just verify` (second terminal) — curl health check; confirms `reasoning_content` splits from `content`.
5. `just pi` — launches the agent pinned to the local provider via `pi --provider local-llm --model qwen3-local`. Without these flags pi defaults to `google` (and will fall back to the `huggingface` built-in provider if `HF_TOKEN` is set, which 403s unless your HF account has Inference Providers access).

## Verification checks

- `curl /v1/models` returns `qwen3-local`.
- `curl /v1/chat/completions` with a trivial prompt returns a response where `reasoning_content` is populated separately from `content`.
- `ps -o rss= -p $(pgrep llama-server)` shows ~28–34GB resident.
- `pi` lists `local-llm` in its model picker; a trivial prompt ("list files in cwd") gets a coherent tool-calling response.

## Gotchas

- If `llama-server` errors with `unknown architecture qwen3moe`, run `brew reinstall --HEAD llama.cpp` to build latest.
- If the `:Q5_K_XL` tag fails to resolve against HF, use `--hf-file Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf` instead.
- First-run HF downloads can stall; Ctrl-C and rerun resumes.

## Paths touched outside the repo

- `/opt/homebrew/bin/llama-server` — brew install target
- `~/.cache/huggingface/hub/models--unsloth--Qwen3.6-35B-A3B-GGUF/` — GGUF download cache (~26GB). Shared HF hub layout; `just clean-cache` removes only this model's subdir so other HF-cached models are untouched.
- `~/.bun/bin/pi` — pi CLI after `bun install -g`
- `~/.pi/agent/models.json` — pi provider config (written by `just configure`)

## Rollback

- Stop server: Ctrl-C.
- Uninstall pi: `bun remove -g @mariozechner/pi-coding-agent`.
- Uninstall llama.cpp: `brew uninstall llama.cpp`.
- Free disk: `just clean-cache`.
