set shell := ["bash", "-euo", "pipefail", "-c"]

# Default: list recipes
default:
    @just --list

# One-time install of required tooling
install:
    brew install llama.cpp
    bun install -g @mariozechner/pi-coding-agent

# Copy models.json and merge settings.json into ~/.pi/agent/. Existing settings.json is backed up to settings.json.bak.<timestamp>.
configure:
    mkdir -p ~/.pi/agent
    cp config/models.json ~/.pi/agent/models.json
    if [ -f ~/.pi/agent/settings.json ]; then cp ~/.pi/agent/settings.json ~/.pi/agent/settings.json.bak.$(date +%Y-%m-%dT%H-%M-%S); fi
    jq -s '.[0] * .[1]' <(cat ~/.pi/agent/settings.json 2>/dev/null || echo '{}') config/settings.json > ~/.pi/agent/settings.json.tmp && mv ~/.pi/agent/settings.json.tmp ~/.pi/agent/settings.json
    @echo "Installed config at ~/.pi/agent/{models,settings}.json"

# Run the local model server (foreground; first run downloads ~26GB to ~/.cache/huggingface/hub)
serve:
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

# Health-check the running server
verify:
    curl -s http://127.0.0.1:8080/v1/models | jq
    curl -s http://127.0.0.1:8080/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"qwen3-local","messages":[{"role":"user","content":"print hello in python"}],"max_tokens":128}' \
      | jq '.choices[0].message'

# Launch pi pinned to the local Qwen server
pi:
    pi --provider local-llm --model qwen3-local

# Everything: install + configure. Then `just serve` in one terminal, `just pi` in another.
setup: install configure

# Remove cached Qwen3.6 GGUF weights (~26GB). Leaves other HuggingFace models intact.
clean-cache:
    rm -rf ~/.cache/huggingface/hub/models--unsloth--Qwen3.6-35B-A3B-GGUF
