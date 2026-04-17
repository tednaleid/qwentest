# qwentest — local Qwen3.6-35B-A3B + pi coding agent

Run [`unsloth/Qwen3.6-35B-A3B-GGUF`](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF) locally via `llama.cpp` and use it as the backing model for the [pi coding agent](https://shittycodingagent.ai).

Target: Apple Silicon Mac with ≥40GB RAM (developed on M1 Ultra / 64GB).

## Requirements

- Homebrew
- [bun](https://bun.sh) (for installing `pi`)
- [just](https://github.com/casey/just) (recipe runner)
- ~30GB free disk for the quantized weights

## Quickstart

```sh
just install               # brew install llama.cpp + bun install -g pi
just configure             # copy config/models.json to ~/.pi/agent/
just serve                 # foreground; first run downloads ~26GB
# in a second terminal:
just verify                # curl the local endpoint
just pi                    # launch the agent
```

`just` with no arguments lists all recipes.

## What this sets up

- `llama-server` serves `Qwen3.6-35B-A3B` (MoE, 3B active / 35B total) at `http://127.0.0.1:8080/v1`
- Quantization: `UD-Q5_K_XL` (~26GB), Flash Attention on, Q8 KV cache
- 64K context window (model supports 262K natively if needed)
- `<think>` output is routed to `reasoning_content` so `pi` doesn't feed thinking tokens back into context
- `pi` is configured with a `local-llm` provider pointing at the server

## Files

- `justfile` — install / configure / serve / verify / pi / clean-cache
- `config/models.json` — pi provider config (installed to `~/.pi/agent/models.json`)
- `config/settings.json` — pi default provider/model/thinking level (merged into `~/.pi/agent/settings.json`)
- `docs/spec/qwen3.6-local-setup.md` — full design + rationale

`just configure` copies `config/models.json` over `~/.pi/agent/models.json` and **merges** `config/settings.json` into the existing `~/.pi/agent/settings.json` (preserving any fields pi writes at runtime, like `lastChangelogVersion`). The prior `settings.json` is backed up to `settings.json.bak.<timestamp>` first, so reruns are safe.

After `just configure`, plain `pi` (without any flags) uses the local Qwen server by default.

## Notes

- No `HF_TOKEN` is required; the model is public.
- Weights are cached in `~/.cache/huggingface/hub/models--unsloth--Qwen3.6-35B-A3B-GGUF/` (standard HF hub layout). Subsequent `just serve` runs reuse the cache — no re-download unless the upstream repo has a new commit.
- If `llama-server` errors with `unknown architecture qwen3moe`, run `brew reinstall --HEAD llama.cpp`.
- Stop the server with Ctrl-C. Clear cached weights with `just clean-cache` (removes only the Qwen3.6 dir, not other HF models you have).
