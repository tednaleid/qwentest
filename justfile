set shell := ["bash", "-euo", "pipefail", "-c"]

# Default: list recipes
default:
    @just --list

# One-time install of required tooling
install:
    brew install llama.cpp
    bun install -g @mariozechner/pi-coding-agent

# Copy pi config into ~/.pi/agent/
configure:
    mkdir -p ~/.pi/agent
    cp config/models.json ~/.pi/agent/models.json
    @echo "Installed config at ~/.pi/agent/models.json"

# Run the local model server (foreground; first run downloads ~26GB to ~/.cache/llama.cpp)
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

# Launch pi
pi:
    pi

# Everything: install + configure. Then `just serve` in one terminal, `just pi` in another.
setup: install configure

# Remove cached GGUF weights (~26GB)
clean-cache:
    rm -rf ~/.cache/llama.cpp
