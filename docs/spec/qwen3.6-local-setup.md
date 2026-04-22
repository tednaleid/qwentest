# Local model setup for `pi` coding agent

## Purpose

Run one of three local GGUF models on Apple Silicon and wire it up as the backing model for the [`pi` coding agent](https://shittycodingagent.ai) (`@mariozechner/pi-coding-agent`):

- `unsloth/Qwen3.6-35B-A3B-GGUF` — MoE, 35B total / 3B active. Fast generalist.
- `unsloth/Qwen3.6-27B-GGUF` — dense 27B. Heavier thinker (Qwen's agentic-coding variant); 3–5× slower per token on Apple Silicon because all weights are read per token, but generally higher per-token quality.
- `unsloth/gemma-4-26B-A4B-it-GGUF` — MoE, 26B total / 4B active.

All three share the same infrastructure: brew `llama.cpp` → `llama-server` with OpenAI-compatible API → pi's `local-llm` provider.

## Key facts

- **All three models are public** on HuggingFace — `HF_TOKEN` is not required.
- **Two MoE + one dense:** The 35B-A3B and 26B-A4B are mixture-of-experts (small active-parameter count, fast on Apple Silicon). The 27B is dense (all weights read per token, slower but heavier per-token reasoning).
- **Architectures:** `qwen3moe` (35B-A3B) and the gemma-4 architecture are already supported by brew's `llama.cpp`. The 27B dense uses the new `qwen35` architecture (hybrid Gated DeltaNet + standard attention) — supported by recent brew releases, with `brew reinstall --HEAD llama.cpp` as a fallback.
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

## Profiles: `xl` (default) and `m`

Two profiles switch the quant + context window as a pair, sized for different RAM budgets:

```
            xl (default, 64GB box)        m (32–36GB box)
 quant:     Q5_K_XL                       Q4_K_M
 context:   -c 131072 (128K)              -c 65536 (64K)
```

Usage: `just serve <model> <profile>`. Profile defaults to `xl`; pass `m` on the 36GB MacBook Pro.

Per-model resident memory (rough estimates, includes weights + KV cache at Q8 + buffers):

| Model | xl (M1 Ultra 64GB) | m (M4 MBP 36GB) |
|---|---|---|
| `qwen-moe` (35B MoE) | ~30–34GB | ~23GB |
| `qwen-dense` (27B) | ~30–34GB | ~24GB |
| `gemma` (26B MoE) | ~26–30GB | ~20GB |

Note: `config/models.json` advertises `contextWindow: 131072` for every model regardless of profile. If you run under `m` and pi requests beyond 64K, the server will error. Simpler than maintaining a second config; acceptable because pi's compaction triggers well below the advertised window in practice.

## Quantization rationale

**35B-A3B / 26B-A4B MoE models** — at 128K context on a 64GB M1 Ultra:
- KV cache runs ~7–8GB with Q8 KV quantization (would be ~14–16GB at F16).
- Q5_K_XL (~26GB model) + KV leaves ~22–24GB headroom for OS + apps — tight but workable.
- Q4_K_XL loses measurable coding quality per unsloth's benchmarks.
- Q6_K_XL (~31GB) + 128K KV gets uncomfortably close to memory pressure.
- Qwen's docs recommend ≥128K to "preserve thinking capabilities"; 64K is fine for short sessions but causes pi's compaction to trigger earlier in long agent loops.

**27B dense** — same `xl` choice (Q5_K_XL at ~20GB) for consistency with the A3B recipe. Simon Willison's launch post used `Q4_K_M` (16.8GB) + 64K context and reported ~25 tok/s with "outstanding" SVG-generation results; his recipe optimizes for broad reach (32GB Macs) and is essentially our `m` profile. On 64GB we have the headroom to spend the extra 3GB on better coding quality, so `xl` uses Q5_K_XL. Dense 27B is slower than the MoE regardless of quant — all ~20GB of weights are read per token, vs. ~2GB for the 3B-active MoE.

## Architecture

```
┌──────────────┐   OpenAI-compatible    ┌───────────────┐
│      pi      │  ───── JSON ────────>  │ llama-server  │
│  (bun CLI)   │  http://localhost:8080 │  (brew/Metal) │
└──────────────┘                        └───────────────┘
                                               │
                                               ▼
                              ~/.cache/huggingface/hub/
                              ├─ models--unsloth--Qwen3.6-35B-A3B-GGUF/   (MoE, ~26GB Q5)
                              ├─ models--unsloth--Qwen3.6-27B-GGUF/       (dense, ~20GB Q5)
                              └─ models--unsloth--gemma-4-26B-A4B-it-GGUF/ (MoE, ~20GB Q5)
```

Only one model is active per `llama-server` run (bound to port 8080). To switch, Ctrl-C the server and run `just serve` with a different `<model>`.

## `llama-server` flag rationale

The `serve` recipe builds the command line from two tables: profile → (quant, context) and model → (HF repo, alias, sampling, per-model extras). The common skeleton is:

```
llama-server \
  -hf $HF:$QUANT \
  --alias $ALIAS \
  -c $CTX \
  -fa on \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --jinja \
  --reasoning-format deepseek \
  "${SAMPLING[@]}" "${EXTRA[@]}" \
  --host 127.0.0.1 --port 8080
```

### Common flags

- `-hf …:$QUANT` — resolves quant tag against the HF repo; downloads to `~/.cache/huggingface/hub/models--unsloth--<repo>/` on first run (standard HF hub layout: content-addressed `blobs/` + human-readable `snapshots/<commit>/*.gguf` symlinks). On subsequent runs, llama-server revalidates the `main` ref and reuses the local blob — no re-download. Different profiles (`xl` vs `m`) download different GGUF files inside the same model directory.
- `--alias` — stable model id so `config/models.json` doesn't depend on the GGUF filename.
- `-c $CTX` — 128K for `xl`, 64K for `m`. 128K matches Qwen's recommended floor for preserving thinking capabilities. Models support longer natively (Qwen up to 262K, 27B up to 1M with YaRN) at the cost of more KV cache.
- `-fa on` + `--cache-type-{k,v} q8_0` — Flash Attention + quantized KV cache roughly halves KV memory with negligible quality cost.
- `--jinja` — applies the model's official chat template.
- `--reasoning-format deepseek` — splits `<think>…</think>` into `reasoning_content` instead of `content`. `pi`'s `openai-completions` adapter ignores `reasoning_content`, so thinking tokens don't get fed back into context.

### Per-model sampling

Unsloth's coding-mode recommendations:

| Model | temp | top_p | top_k |
|---|---|---|---|
| `qwen-moe`, `qwen-dense` | 0.6 | 0.95 | 20 |
| `gemma` | 1.0 | 0.95 | 64 |

### Per-model extras

- **`qwen-moe`** — `--no-mmproj`. Qwen3.6 is multimodal; the `-hf` downloader would otherwise pull `mmproj-BF16.gguf` (~861MB) and load it into RAM. We use pi as a CLI coding agent so the vision tower is pure overhead.
- **`qwen-dense`** — `--no-mmproj` (same reason) plus `--chat-template-kwargs '{"preserve_thinking": true}'`. The latter tells the Jinja template to keep prior-turn `<think>` blocks in the rendered prompt, which Qwen3.6-dense is trained to exploit for multi-turn reasoning continuity. Per Simon Willison's launch recipe.
- **`gemma`** — no extras.

### Fallback

If a quant tag fails to resolve (rare, usually means a new quant in the repo the `llama.cpp` release doesn't recognize), fall back to explicit file selection, e.g. `--hf-file Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf`.

## pi provider config

Each `just serve` run installs two files:

- `config/models.json` → copied to `~/.pi/agent/models.json` (defines the `local-llm` provider with one entry per model). pi hot-reloads this file — no restart needed.
- `config/settings.json` → **merged** into `~/.pi/agent/settings.json` using `jq -s '.[0] * .[1] * {"defaultModel": "$ALIAS"}'` so pi's runtime-written fields (e.g. `lastChangelogVersion`) are preserved, while `defaultModel` is overwritten to match the model being served. The existing settings file is backed up to `~/.pi/agent/settings.json.bak.<ISO-timestamp>` before the merge, so reruns are non-destructive.

`config/settings.json` sets:
```json
{
  "defaultProvider": "local-llm",
  "defaultModel": "qwen-moe-local",
  "defaultThinkingLevel": "medium"
}
```
This makes bare `pi` default to the local server — no `--provider`/`--model` flags needed. `defaultModel` in the on-disk file tracks whichever model was most recently served.

`config/models.json` exposes three entries under the `local-llm` provider (`qwen-moe-local`, `qwen-dense-local`, `gemma4-local`), all with `reasoning: true`, text-only input, `contextWindow: 131072`, zero cost.

## Workflow

1. `just serve <model> [profile]` — foreground. Installs deps (brew + bun, no-ops if present), configures pi (backs up any existing `~/.pi/agent/settings.json`, merges ours on top), then starts `llama-server`. First run for a given model+quant combo downloads weights to `~/.cache/huggingface/hub/`.
2. `just verify` (second terminal) — auto-detects the currently-served model via `/v1/models` and runs a curl health check; confirms `reasoning_content` splits from `content`.
3. `just pi` — launches the agent. Because `config/settings.json` is merged in with `defaultProvider: local-llm` and `defaultModel: <alias>`, bare `pi` also works without flags.

## Verification checks

- `curl /v1/models` returns the alias for the currently-served model (`qwen-moe-local`, `qwen-dense-local`, or `gemma4-local`).
- `curl /v1/chat/completions` with a trivial prompt returns a response where `reasoning_content` is populated separately from `content`.
- `ps -o rss= -p $(pgrep llama-server)` shows ~20–34GB resident depending on model + profile.
- `pi` lists `local-llm` in its model picker; a trivial prompt ("list files in cwd") gets a coherent tool-calling response.

## Gotchas

- If `llama-server` errors with `unknown architecture qwen3moe` / `qwen35` / gemma-4 equivalent, run `brew reinstall --HEAD llama.cpp` to build latest.
- If a quant tag fails to resolve against HF, use `--hf-file <exact-filename>.gguf` instead.
- First-run HF downloads can stall; Ctrl-C and rerun resumes.
- `qwen-dense` runs much slower than `qwen-moe` on the same hardware — expected (dense 27B reads all weights per token vs. MoE's ~2GB of active weights).

## Paths touched outside the repo

- `/opt/homebrew/bin/llama-server` — brew install target
- `~/.cache/huggingface/hub/models--unsloth--Qwen3.6-35B-A3B-GGUF/` — MoE cache (~26GB at Q5, ~20GB at Q4)
- `~/.cache/huggingface/hub/models--unsloth--Qwen3.6-27B-GGUF/` — dense cache (~20GB at Q5, ~17GB at Q4)
- `~/.cache/huggingface/hub/models--unsloth--gemma-4-26B-A4B-it-GGUF/` — Gemma cache (~20GB at Q5)
- Standard HF hub layout; `just clean-cache <model>` removes only that model's subdir so other HF-cached models are untouched.
- `~/.bun/bin/pi` — pi CLI after `bun install -g`
- `~/.pi/agent/models.json` + `~/.pi/agent/settings.json` — pi config (written by `just serve`)

## Rollback

- Stop server: Ctrl-C.
- Uninstall pi: `bun remove -g @mariozechner/pi-coding-agent`.
- Uninstall llama.cpp: `brew uninstall llama.cpp`.
- Free disk: `just clean-cache qwen-moe` (or `qwen-dense` / `gemma`).
