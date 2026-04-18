set shell := ["bash", "-euo", "pipefail", "-c"]

# Default: list recipes
default:
    @just --list

# Install tooling, configure pi, and start the model server (qwen or gemma). First run downloads weights.
serve model="qwen":
    #!/usr/bin/env bash
    set -euo pipefail

    # Install dependencies (no-ops if already present)
    brew install llama.cpp
    bun install -g @mariozechner/pi-coding-agent

    # Configure pi for the selected model
    case "{{model}}" in
      qwen)  MODEL_ID="qwen3-local" ;;
      gemma) MODEL_ID="gemma4-local" ;;
      *)     echo "Unknown model: {{model}} (use 'qwen' or 'gemma')"; exit 1 ;;
    esac
    mkdir -p ~/.pi/agent
    cp config/models.json ~/.pi/agent/models.json
    if [ -f ~/.pi/agent/settings.json ]; then
      cp ~/.pi/agent/settings.json ~/.pi/agent/settings.json.bak.$(date +%Y-%m-%dT%H-%M-%S)
    fi
    jq -s '.[0] * .[1] * {"defaultModel": "'"$MODEL_ID"'"}' \
      <(cat ~/.pi/agent/settings.json 2>/dev/null || echo '{}') \
      config/settings.json \
      > ~/.pi/agent/settings.json.tmp && mv ~/.pi/agent/settings.json.tmp ~/.pi/agent/settings.json
    echo "Configured pi for $MODEL_ID"

    # Start the server
    case "{{model}}" in
      qwen)
        exec llama-server \
          -hf unsloth/Qwen3.6-35B-A3B-GGUF:Q5_K_XL \
          --alias qwen3-local \
          -c 131072 -fa on \
          --cache-type-k q8_0 --cache-type-v q8_0 \
          --jinja --reasoning-format deepseek \
          --temp 0.6 --top-p 0.95 --top-k 20 \
          --host 127.0.0.1 --port 8080
        ;;
      gemma)
        exec llama-server \
          -hf unsloth/gemma-4-26B-A4B-it-GGUF:Q5_K_XL \
          --alias gemma4-local \
          -c 131072 -fa on \
          --cache-type-k q8_0 --cache-type-v q8_0 \
          --jinja --reasoning-format deepseek \
          --temp 1.0 --top-p 0.95 --top-k 64 \
          --host 127.0.0.1 --port 8080
        ;;
    esac

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
      qwen)  rm -rf ~/.cache/huggingface/hub/models--unsloth--Qwen3.6-35B-A3B-GGUF; echo "Removed Qwen3.6 cache" ;;
      gemma) rm -rf ~/.cache/huggingface/hub/models--unsloth--gemma-4-26B-A4B-it-GGUF; echo "Removed Gemma 4 cache" ;;
      *)     echo "Unknown model: {{model}} (use 'qwen' or 'gemma')"; exit 1 ;;
    esac
