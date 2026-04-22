# qwentest — local Qwen3.6 / Gemma 4 + pi coding agent

Run one of three local models via `llama.cpp` and use it as the backing model for the [pi coding agent](https://shittycodingagent.ai):

- [`unsloth/Qwen3.6-35B-A3B-GGUF`](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF) — MoE, 35B total / 3B active. Fast generalist.
- [`unsloth/Qwen3.6-27B-GGUF`](https://huggingface.co/unsloth/Qwen3.6-27B-GGUF) — dense 27B. Heavier thinker; 3–5× slower per token but higher per-token quality. Positioned by Qwen for agentic coding / repo-level reasoning.
- [`unsloth/gemma-4-26B-A4B-it-GGUF`](https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF) — MoE, 26B total / 4B active.

Target: Apple Silicon Mac with ≥36GB RAM. Developed on M1 Ultra / 64GB; the `m` profile below also supports 32–36GB boxes (e.g. M4 MacBook Pro).

## Requirements

- Homebrew
- [bun](https://bun.sh) (for installing `pi`)
- [just](https://github.com/casey/just) (recipe runner)
- [jq](https://jqlang.github.io/jq/) (used by `serve` to merge pi settings)
- ~20–30GB free disk per model/quant for the weights

## Quickstart

```sh
just serve qwen-moe              # 64GB Mac (default: profile=xl, Q5_K_XL + 128K ctx)
# or
just serve qwen-dense            # same, but the dense 27B variant (heavier thinker)
# or
just serve qwen-dense m          # 32–36GB Mac (profile=m, Q4_K_M + 64K ctx)
# or
just serve gemma                 # Gemma 4 26B-A4B MoE

# in a second terminal:
just verify                      # curl the local endpoint
just pi                          # launch the agent against the configured model
```

`just` with no arguments lists all recipes. The first `serve` run for each model + quant combo downloads ~17–26GB of weights.

## Profiles

```
            xl (default, 64GB box)        m (32–36GB box)
 quant:     Q5_K_XL (higher quality)      Q4_K_M (smaller, still strong)
 context:   128K (-c 131072)              64K (-c 65536)
```

Per-model resident memory (rough):

| Model | xl | m |
|---|---|---|
| `qwen-moe` (35B MoE) | ~30–34GB | ~23GB |
| `qwen-dense` (27B) | ~30–34GB | ~24GB |
| `gemma` (26B MoE) | ~26–30GB | ~20GB |

## What `serve` does

1. `brew install llama.cpp` and `bun install -g @mariozechner/pi-coding-agent` (no-ops if already present).
2. Copies `config/models.json` to `~/.pi/agent/models.json`.
3. Merges `config/settings.json` into `~/.pi/agent/settings.json`, setting `defaultModel` to match the selected model. The prior settings file is backed up to `settings.json.bak.<timestamp>` first.
4. Starts `llama-server` at `http://127.0.0.1:8080/v1` with the selected model and profile.

Common server flags: Flash Attention on, Q8 KV cache, `--jinja --reasoning-format deepseek` so `<think>` output is routed to `reasoning_content` and not fed back into context, `--no-mmproj` to skip the multimodal projector (we're CLI-only). Sampling temps follow each model's recommended defaults (Qwen: 0.6, Gemma: 1.0). `qwen-dense` additionally uses `--chat-template-kwargs '{"preserve_thinking": true}'` to keep `<think>` blocks across turns for multi-turn reasoning continuity.

After `serve` runs, plain `pi` (no flags) uses whichever local model you last started.

## Files

- `justfile` — `serve` / `verify` / `pi` / `clean-cache`
- `config/models.json` — pi provider config exposing `qwen-moe-local`, `qwen-dense-local`, `gemma4-local`
- `config/settings.json` — pi default provider/thinking level (merged into `~/.pi/agent/settings.json`)
- `docs/spec/qwen3.6-local-setup.md` — full design + rationale

## Notes

- No `HF_TOKEN` is required; all three models are public.
- Weights are cached under `~/.cache/huggingface/hub/models--unsloth--Qwen3.6-35B-A3B-GGUF/`, `models--unsloth--Qwen3.6-27B-GGUF/`, and `models--unsloth--gemma-4-26B-A4B-it-GGUF/`. Subsequent `just serve` runs reuse the cache. Different profiles (`xl` vs `m`) download different GGUF files inside the same model directory.
- If `llama-server` errors with `unknown architecture qwen3moe` / `qwen35` / gemma equivalent, run `brew reinstall --HEAD llama.cpp`.
- Stop the server with Ctrl-C.
- `just clean-cache qwen-moe` / `qwen-dense` / `gemma` removes only that model's weights; other HuggingFace models are left intact.
