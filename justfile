set shell := ["bash", "-euo", "pipefail", "-c"]

# Default: list recipes
default:
    @just --list

# Install tooling, configure pi, start the server. model: qwen-moe|qwen-dense|gemma. profile: xl (64GB) | m (36GB).
serve model="qwen-moe" profile="xl":
    #!/usr/bin/env bash
    set -euo pipefail

    # Install dependencies (no-ops if already present)
    brew install llama.cpp
    bun install -g @mariozechner/pi-coding-agent

    # profile → quant + context
    case "{{profile}}" in
      xl) QUANT="Q5_K_XL"; CTX=131072 ;;
      m)  QUANT="Q4_K_M";  CTX=65536  ;;
      *)  echo "Unknown profile: {{profile}} (use 'xl' or 'm')"; exit 1 ;;
    esac

    # model → HF repo + alias + sampling + per-model extras
    case "{{model}}" in
      qwen-moe)
        HF="unsloth/Qwen3.6-35B-A3B-GGUF"
        ALIAS="qwen-moe-local"
        SAMPLING=(--temp 0.6 --top-p 0.95 --top-k 20)
        EXTRA=(--no-mmproj)
        ;;
      qwen-dense)
        HF="unsloth/Qwen3.6-27B-GGUF"
        ALIAS="qwen-dense-local"
        SAMPLING=(--temp 0.6 --top-p 0.95 --top-k 20)
        EXTRA=(--no-mmproj --chat-template-kwargs '{"preserve_thinking": true}')
        ;;
      gemma)
        HF="unsloth/gemma-4-26B-A4B-it-GGUF"
        ALIAS="gemma4-local"
        SAMPLING=(--temp 1.0 --top-p 0.95 --top-k 64)
        EXTRA=()
        ;;
      *)
        echo "Unknown model: {{model}} (use 'qwen-moe', 'qwen-dense', or 'gemma')"
        exit 1
        ;;
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
    exec llama-server \
      -hf "$HF:$QUANT" \
      --alias "$ALIAS" \
      -c "$CTX" -fa on \
      --cache-type-k q8_0 --cache-type-v q8_0 \
      --jinja --reasoning-format deepseek \
      "${SAMPLING[@]}" "${EXTRA[@]}" \
      --host 127.0.0.1 --port 8080

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
    case "{{model}}" in
      qwen-moe)   rm -rf ~/.cache/huggingface/hub/models--unsloth--Qwen3.6-35B-A3B-GGUF; echo "Removed Qwen3.6 MoE cache" ;;
      qwen-dense) rm -rf ~/.cache/huggingface/hub/models--unsloth--Qwen3.6-27B-GGUF; echo "Removed Qwen3.6 dense cache" ;;
      gemma)      rm -rf ~/.cache/huggingface/hub/models--unsloth--gemma-4-26B-A4B-it-GGUF; echo "Removed Gemma 4 cache" ;;
      *)          echo "Unknown model: {{model}} (use 'qwen-moe', 'qwen-dense', or 'gemma')"; exit 1 ;;
    esac
