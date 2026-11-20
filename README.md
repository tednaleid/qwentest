# qwentest: local Qwen / Gemma / Inkling + pi coding agent

Run one of four local models via `llama.cpp` and use it as the backing model for the [pi coding agent](https://pi.dev):

| `serve` name | Model | Shape |
|---|---|---|
| `qwen-moe` | [`unsloth/Qwen3.6-35B-A3B-GGUF`](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF) | MoE, 35B total / 3B active. Fast generalist. |
| `qwen-dense` | [`unsloth/Qwen3.8-27B-GGUF`](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) | Dense 27B. Slower per token, positioned by Qwen for agentic coding. |
| `gemma` | [`unsloth/gemma-4-26B-A4B-it-GGUF`](https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF) | MoE, 26B total / 4B active. |
| `inkling` | [`ggml-org/Inkling-2-Mini-GGUF`](https://huggingface.co/ggml-org/Inkling-2-Mini-GGUF) | Looped MoE, 26B total / 3.4B active. Needs a source build of llama.cpp, see below. |

Target: Apple Silicon Mac with ≥36GB RAM. Developed on M1 Ultra / 64GB; the `m` profile below also supports 32–36GB boxes (e.g. M4 MacBook Pro).

## Requirements

- Homebrew
- [bun](https://bun.sh) (for installing `pi`) and Node ≥ 22.19 (pi runs on it)
- [just](https://github.com/casey/just) (recipe runner)
- [jq](https://jqlang.github.io/jq/) (used by `serve` to merge pi settings)
- ~17–30GB free disk per model/quant for the weights

## Quickstart

```sh
just serve qwen-moe              # 64GB Mac (default: profile=xl, 128K ctx)
# or
just serve qwen-dense            # Qwen3.8-27B dense
# or
just serve qwen-dense m          # 32–36GB Mac (profile=m, smaller quant + 64K ctx)
# or
just serve gemma                 # Gemma 4 26B-A4B MoE
# or
just build-llama-inkling         # once per machine, see "Inkling 2 Mini"
just serve inkling               # Inkling 2 Mini

# in a second terminal:
just verify                      # curl the local endpoint
just pi                          # launch the agent against the configured model
```

`just` with no arguments lists all recipes. The first `serve` run for each model + quant combo downloads the weights.

## Profiles

The profile sets the context size and picks each model's quant:

| Model | `xl` (64GB box, 128K ctx) | `m` (32–36GB box, 64K ctx) |
|---|---|---|
| `qwen-moe` | `Q5_K_XL` | `Q4_K_M` |
| `qwen-dense` | `UD-Q6_K` (22GB) | `UD-Q4_K_M` (17GB) |
| `gemma` | `Q5_K_XL` | `Q4_K_M` |
| `inkling` | `Q8_0` (28GB) | `IQ4_NL` (18GB) |

Resident memory on the M1 Ultra with the `xl` profile, shortly after load: `qwen-dense` ~26GB, `inkling` ~25GB, `qwen-moe` ~30–34GB. Memory grows as the context fills.

Generation speed on the M1 Ultra with `xl`: `qwen-dense` ~16 tokens/sec, `inkling` ~22 tokens/sec.

## Inkling 2 Mini

Inkling 2 Mini support was merged into llama.cpp in [ggml-org/llama.cpp#32694](https://github.com/ggml-org/llama.cpp/pull/32694). Homebrew's llama.cpp 1.0.0 (build 12359) predates that merge and fails to load the model.

`just build-llama-inkling` installs `cmake`, clones llama.cpp into `~/.cache/qwentest/llama.cpp-inkling` (outside this Dropbox-synced repo), checks out the merge commit, and builds `llama-server` with Metal. `just serve inkling` uses that binary; the other models use Homebrew's.

When a Homebrew llama.cpp release includes the merge, `serve inkling` can use the Homebrew binary and the build recipe can be removed.

The GGUFs come from `ggml-org` because their metadata matches what upstream llama.cpp loads. The top-level files in `unsloth/Inkling-2-Mini-GGUF` use a different layout that upstream rejects (`key not found in model` / `tensor 'blk.24.attn_q.weight' not found`).

Inkling reasons by default and its model card warns it can get stuck in long reasoning loops; pi's `maxTokens` (8192) caps each response. The server accepts a per-request `reasoning_effort` (`minimal`, `low`, `medium`, `high`, `xhigh`), default `high`.

## What `serve` does

1. `brew install llama.cpp` and `bun install -g @earendil-works/pi-coding-agent` (no-ops if already present). `just update` upgrades both.
2. Copies `config/models.json` to `~/.pi/agent/models.json`.
3. Merges `config/settings.json` into `~/.pi/agent/settings.json`, setting `defaultModel` to match the selected model. The prior settings file is backed up to `settings.json.bak.<timestamp>` first.
4. Starts `llama-server` at `http://127.0.0.1:8080/v1` with the selected model and profile.

Common server flags: Flash Attention on, Q8 KV cache, `--jinja --reasoning-format deepseek` so thinking output is routed to `reasoning_content`. Each model's vision projector is downloaded and loaded with it, so pi can attach images (`pi @screenshot.png "..."`).

Sampling follows each model's recommended defaults:

| Model | Sampling | Reasoning |
|---|---|---|
| `qwen-moe` | temp 0.6, top-p 0.95, top-k 20 | template default |
| `qwen-dense` | temp 1.0, top-p 0.95, top-k 20 | `--reasoning-effort medium` (the template default is `xhigh`) |
| `gemma` | temp 1.0, top-p 0.95, top-k 64 | template default |
| `inkling` | temp 1.0, top-p 1.0, top-k 0, min-p 0.0 | template default (`high`) |

After `serve` runs, plain `pi` (no flags) uses whichever local model you last started.

## Files

- `justfile`: `serve` / `verify` / `pi` / `update` / `build-llama-inkling` / `clean-cache`
- `config/models.json`: pi provider config exposing `qwen-moe-local`, `qwen-dense-local`, `gemma4-local`, `inkling-local`
- `config/settings.json`: pi default provider/thinking level (merged into `~/.pi/agent/settings.json`)
- `docs/spec/qwen3.6-local-setup.md`: the original April 2026 design and rationale

## Notes

- No `HF_TOKEN` is required; all four models are public.
- Weights are cached under `~/.cache/huggingface/hub/models--<org>--<repo>/`. Subsequent `just serve` runs reuse the cache. Different profiles (`xl` vs `m`) download different GGUF files inside the same model directory.
- If `llama-server` errors with an unknown architecture for a Qwen or Gemma model, run `just update`.
- Stop the server with Ctrl-C.
- `just clean-cache <model>` removes only that model's weights; other HuggingFace models are left intact.
- The `m` profile and `gemma` have not been run since the move to pi 1.x and llama.cpp 1.0.0.
