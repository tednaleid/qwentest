set shell := ["bash", "-euo", "pipefail", "-c"]

# llama.cpp checkout with Inkling 2 Mini support, kept outside Dropbox
inkling_llama_dir := env("HOME") / ".cache/qwentest/llama.cpp-inkling"
# Merge commit of ggml-org/llama.cpp#32694, which adds the looped Inkling 2 Mini architecture
inkling_llama_commit := "29b52d398b294509746ec0a3f28948a3107c0213"

# Default: list recipes
default:
    @just --list

# Install tooling, configure pi, start the server. model: qwen-moe|qwen-dense|gemma|inkling. profile: xl (64GB) | m (36GB).
serve model="qwen-moe" profile="xl":
    #!/usr/bin/env bash
    set -euo pipefail

    # Install dependencies (no-ops if already present)
    brew install llama.cpp
    bun install -g @earendil-works/pi-coding-agent

    HF=$({{just_executable()}} --justfile "{{justfile()}}" hf-repo "{{model}}")

    # model → alias + quant per profile + sampling + per-model extras
    SERVER="llama-server"
    case "{{model}}" in
      qwen-moe)
        ALIAS="qwen-moe-local"
        XL_QUANT="Q5_K_XL"; M_QUANT="Q4_K_M"
        SAMPLING=(--temp 0.6 --top-p 0.95 --top-k 20)
        EXTRA=()
        ;;
      qwen-dense)
        ALIAS="qwen-dense-local"
        XL_QUANT="UD-Q6_K"; M_QUANT="UD-Q4_K_M"
        SAMPLING=(--temp 1.0 --top-p 0.95 --top-k 20)
        EXTRA=(--reasoning-effort medium)
        ;;
      gemma)
        ALIAS="gemma4-local"
        XL_QUANT="Q5_K_XL"; M_QUANT="Q4_K_M"
        SAMPLING=(--temp 1.0 --top-p 0.95 --top-k 64)
        EXTRA=()
        ;;
      inkling)
        ALIAS="inkling-local"
        XL_QUANT="Q8_0"; M_QUANT="IQ4_NL"
        SAMPLING=(--temp 1.0 --top-p 1.0 --top-k 0 --min-p 0.0)
        EXTRA=()
        SERVER="{{inkling_llama_dir}}/build/bin/llama-server"
        if [ ! -x "$SERVER" ]; then
          echo "Inkling needs a llama.cpp build with Inkling 2 Mini support. Run: just build-llama-inkling"
          exit 1
        fi
        ;;
    esac

    # profile → quant + context
    case "{{profile}}" in
      xl) QUANT="$XL_QUANT"; CTX=131072 ;;
      m)  QUANT="$M_QUANT";  CTX=65536  ;;
      *)  echo "Unknown profile: {{profile}} (use 'xl' or 'm')"; exit 1 ;;
    esac

    # Configure pi for the selected model
    mkdir -p ~/.pi/agent
    cp config/models.json ~/.pi/agent/models.json
    if [ -f ~/.pi/agent/settings.json ]; then
      cp ~/.pi/agent/settings.json ~/.pi/agent/settings.json.bak.$(date +%Y-%m-%dT%H-%M-%S)
    fi
    jq -s '.[0] * .[1] * {"defaultModel": "'"$ALIAS"'"}' \
      <(cat ~/.pi/agent/settings.json 2>/dev/null || echo '{}') \
      config/settings.json \
      > ~/.pi/agent/settings.json.tmp && mv ~/.pi/agent/settings.json.tmp ~/.pi/agent/settings.json
    echo "Configured pi for $ALIAS ($QUANT, ${CTX} ctx)"

    # Start the server
    exec "$SERVER" \
      -hf "$HF:$QUANT" \
      --alias "$ALIAS" \
      -c "$CTX" -fa on \
      --cache-type-k q8_0 --cache-type-v q8_0 \
      --jinja --reasoning-format deepseek \
      "${SAMPLING[@]}" ${EXTRA[@]+"${EXTRA[@]}"} \
      --host 127.0.0.1 --port 8080

# Build llama-server from the llama.cpp commit that adds Inkling 2 Mini, for Homebrew builds that predate it
build-llama-inkling:
    #!/usr/bin/env bash
    set -euo pipefail
    brew install cmake
    DIR="{{inkling_llama_dir}}"
    mkdir -p "$(dirname "$DIR")"
    [ -d "$DIR/.git" ] || git clone --filter=blob:none https://github.com/ggml-org/llama.cpp.git "$DIR"
    cd "$DIR"
    git fetch origin master
    git checkout --detach "{{inkling_llama_commit}}"
    cmake -B build -DCMAKE_BUILD_TYPE=Release -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
    cmake --build build --config Release -j --target llama-server
    build/bin/llama-server --version

# Upgrade llama.cpp and pi to their latest releases
update:
    brew upgrade llama.cpp
    bun install -g @earendil-works/pi-coding-agent@latest

# Health-check the running server (auto-detects which model is loaded)
verify:
    #!/usr/bin/env bash
    set -euo pipefail
    curl -s http://127.0.0.1:8080/v1/models | jq
    MODEL_ID=$(curl -s http://127.0.0.1:8080/v1/models | jq -r '.data[0].id')
    curl -s http://127.0.0.1:8080/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"'"$MODEL_ID"'","messages":[{"role":"user","content":"print hello in python"}],"max_tokens":128}' \
      | jq '.choices[0].message'

# Launch pi (uses default model from ~/.pi/agent/settings.json, set by serve)
pi:
    pi

# Remove cached model weights. Leaves other HuggingFace models intact.
clean-cache model:
    #!/usr/bin/env bash
    set -euo pipefail
    HF=$({{just_executable()}} --justfile "{{justfile()}}" hf-repo "{{model}}")
    CACHE_DIR="$HOME/.cache/huggingface/hub/models--${HF//\//--}"
    rm -rf "$CACHE_DIR"
    echo "Removed $CACHE_DIR"

# Print the HuggingFace GGUF repo for a model name
[private]
hf-repo model:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{model}}" in
      qwen-moe)   echo "unsloth/Qwen3.6-35B-A3B-GGUF" ;;
      qwen-dense) echo "unsloth/Qwen3.8-27B-GGUF" ;;
      gemma)      echo "unsloth/gemma-4-26B-A4B-it-GGUF" ;;
      inkling)    echo "ggml-org/Inkling-2-Mini-GGUF" ;;
      *)          echo "Unknown model: {{model}} (use 'qwen-moe', 'qwen-dense', 'gemma', or 'inkling')" >&2; exit 1 ;;
    esac
