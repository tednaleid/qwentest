# qwentest — local Qwen3.6 / Gemma 4 + pi coding agent

Run one of two local MoE models via `llama.cpp` and use it as the backing model for the [pi coding agent](https://shittycodingagent.ai):

- [`unsloth/Qwen3.6-35B-A3B-GGUF`](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF) — 35B total / 3B active
- [`unsloth/gemma-4-26B-A4B-it-GGUF`](https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF) — 26B total / 4B active

Target: Apple Silicon Mac with ≥40GB RAM (developed on M1 Ultra / 64GB).

## Requirements

- Homebrew
- [bun](https://bun.sh) (for installing `pi`)
- [just](https://github.com/casey/just) (recipe runner)
- [jq](https://jqlang.github.io/jq/) (used by `serve` to merge pi settings)
- ~30GB free disk per model for the quantized weights

## Quickstart

```sh
just serve qwen        # installs deps, configures pi, serves Qwen3.6 (default)
# or
just serve gemma       # same, but serves Gemma 4

# in a second terminal:
just verify            # curl the local endpoint
just pi                # launch the agent against the configured model
```

`just` with no arguments lists all recipes. The first `serve` run for each model downloads ~26GB of weights.

## What `serve` does

1. `brew install llama.cpp` and `bun install -g @mariozechner/pi-coding-agent` (no-ops if already present).
2. Copies `config/models.json` to `~/.pi/agent/models.json`.
3. Merges `config/settings.json` into `~/.pi/agent/settings.json`, setting `defaultModel` to match the selected model. The prior settings file is backed up to `settings.json.bak.<timestamp>` first.
4. Starts `llama-server` at `http://127.0.0.1:8080/v1` with the selected model.

Common server flags for both models: `-c 131072` (128K context), Flash Attention on, Q8 KV cache, `--jinja --reasoning-format deepseek` so `<think>` output is routed to `reasoning_content` and not fed back into context. Sampling temps follow each model's recommended defaults (Qwen: 0.6, Gemma: 1.0).

After `serve` runs, plain `pi` (no flags) uses whichever local model you last started.

## Files

- `justfile` — `serve` / `verify` / `pi` / `clean-cache`
- `config/models.json` — pi provider config exposing both `qwen3-local` and `gemma4-local`
- `config/settings.json` — pi default provider/thinking level (merged into `~/.pi/agent/settings.json`)
- `docs/spec/qwen3.6-local-setup.md` — full design + rationale

## Notes

- No `HF_TOKEN` is required; both models are public.
- Weights are cached under `~/.cache/huggingface/hub/models--unsloth--Qwen3.6-35B-A3B-GGUF/` and `~/.cache/huggingface/hub/models--unsloth--gemma-4-26B-A4B-it-GGUF/`. Subsequent `just serve` runs reuse the cache.
- If `llama-server` errors with `unknown architecture qwen3moe` (or similar for gemma), run `brew reinstall --HEAD llama.cpp`.
- Stop the server with Ctrl-C.
- `just clean-cache qwen` or `just clean-cache gemma` removes only that model's weights; other HuggingFace models are left intact.
