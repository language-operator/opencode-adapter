#!/bin/sh
# Runs inside the container image to verify seed-config.mjs behaviour.
# Exit 0 = all pass, non-zero = failure.
set -e

PASS=0
FAIL=0

assert() {
  local desc="$1"; local cmd="$2"
  if eval "$cmd" > /dev/null 2>&1; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

set_config() {
  mkdir -p /etc/agent
  cat > /etc/agent/config.yaml
}

clear_config() {
  rm -f /etc/agent/config.yaml
}

# ---------------------------------------------------------------------------
# Test 1: full config.yaml mapping
# ---------------------------------------------------------------------------
echo "--- Test 1: full config.yaml mapping ---"

set_config << 'EOF'
agent:
  name: test-agent
tools:
  my-tool:
    endpoint: http://my-tool.default.svc.cluster.local:8080
    protocol: mcp
models:
  claude-sonnet:
    model: claude-sonnet-4-5
    endpoint: http://gateway.default.svc.cluster.local:8000
EOF

mkdir -p /tmp/t1
OPENCODE_CONFIG_DIR=/tmp/t1 \
  node /app/seed-config.mjs > /tmp/t1/out.txt 2>&1
clear_config

assert "opencode.jsonc created"          "[ -f /tmp/t1/opencode.jsonc ]"
assert "provider present"                "grep -q 'provider' /tmp/t1/opencode.jsonc"
assert "provider key is openai"          "grep -q '\"openai\"' /tmp/t1/opencode.jsonc"
assert "options.baseURL set"             "grep -q 'baseURL' /tmp/t1/opencode.jsonc"
assert "correct baseURL value"           "grep -q 'gateway.default.svc.*8000/v1' /tmp/t1/opencode.jsonc"
assert "model id as record key"          "grep -q 'claude-sonnet-4-5' /tmp/t1/opencode.jsonc"
assert "placeholder apiKey"              "grep -q 'sk-langop-proxy' /tmp/t1/opencode.jsonc"
assert "mcp section present"             "grep -q 'mcp' /tmp/t1/opencode.jsonc"
assert "mcp tool key"                    "grep -q 'my-tool' /tmp/t1/opencode.jsonc"
assert "mcp type: remote"                "grep -q 'remote' /tmp/t1/opencode.jsonc"
assert "mcp tool url"                    "grep -q 'my-tool.default.svc' /tmp/t1/opencode.jsonc"
assert "autoupdate: false"               "grep -q 'autoupdate' /tmp/t1/opencode.jsonc"

# ---------------------------------------------------------------------------
# Test 2: always overwrites (no skip-if-exists — config is operator-managed)
# ---------------------------------------------------------------------------
echo "--- Test 2: always overwrites existing config ---"

set_config << 'EOF'
models:
  new-model:
    model: gpt-4o
    endpoint: http://gateway.default.svc.cluster.local:8000
EOF

mkdir -p /tmp/t2
echo '{"old": true}' > /tmp/t2/opencode.jsonc

OPENCODE_CONFIG_DIR=/tmp/t2 \
  node /app/seed-config.mjs > /tmp/t2/out.txt 2>&1
clear_config

assert "config overwritten"              "! grep -q '\"old\"' /tmp/t2/opencode.jsonc"
assert "new model present"               "grep -q 'gpt-4o' /tmp/t2/opencode.jsonc"

# ---------------------------------------------------------------------------
# Test 3: env var fallback (no config.yaml)
# ---------------------------------------------------------------------------
echo "--- Test 3: env var fallback ---"

mkdir -p /tmp/t3

MODEL_ENDPOINT=http://gateway.default.svc.cluster.local:8000 \
  LLM_MODEL=claude-sonnet-4-5 \
  OPENCODE_CONFIG_DIR=/tmp/t3 \
  node /app/seed-config.mjs > /tmp/t3/out.txt 2>&1

assert "opencode.jsonc created"          "[ -f /tmp/t3/opencode.jsonc ]"
assert "provider key is openai"          "grep -q '\"openai\"' /tmp/t3/opencode.jsonc"
assert "provider populated from env"     "grep -q 'gateway.default.svc.*8000/v1' /tmp/t3/opencode.jsonc"
assert "model name from LLM_MODEL"       "grep -q 'claude-sonnet-4-5' /tmp/t3/opencode.jsonc"

# ---------------------------------------------------------------------------
# Test 4: no config.yaml, no env vars → graceful minimal config
# ---------------------------------------------------------------------------
echo "--- Test 4: graceful empty (no config, no env vars) ---"

mkdir -p /tmp/t4

OPENCODE_CONFIG_DIR=/tmp/t4 \
  node /app/seed-config.mjs > /tmp/t4/out.txt 2>&1

assert "opencode.jsonc still created"    "[ -f /tmp/t4/opencode.jsonc ]"
assert "autoupdate: false present"       "grep -q 'autoupdate' /tmp/t4/opencode.jsonc"

# ---------------------------------------------------------------------------
# Test 5: instructions → seed script + default model
# ---------------------------------------------------------------------------
echo "--- Test 5: instructions produce seed script and default model ---"

set_config << 'EOF'
agent:
  name: greeter
instructions: |-
  Say hello and introduce yourself.
  Mention you are "Claude".
models:
  claude-sonnet:
    model: claude-sonnet-4-5
    endpoint: http://gateway.default.svc.cluster.local:8000
EOF

mkdir -p /tmp/t5
AGENT_NAME=greeter \
  OPENCODE_CONFIG_DIR=/tmp/t5 \
  node /app/seed-config.mjs > /tmp/t5/out.txt 2>&1
clear_config

assert "default model in opencode.jsonc"   "grep -q '\"model\": \"openai/claude-sonnet-4-5\"' /tmp/t5/opencode.jsonc"
assert "instructions.txt written"          "[ -f /tmp/t5/instructions.txt ]"
assert "instructions content verbatim"     "grep -q 'introduce yourself' /tmp/t5/instructions.txt"
assert "multi-line instructions preserved" "grep -q 'Claude' /tmp/t5/instructions.txt"
assert "seed.sh written"                    "[ -f /tmp/t5/seed.sh ]"
assert "seed.sh uses correct model"        "grep -q \"openai/claude-sonnet-4-5\" /tmp/t5/seed.sh"
assert "seed.sh title from agent name"     "grep -q 'greeter instructions' /tmp/t5/seed.sh"
assert "seed.sh reads instructions via stdin" "grep -q '< /tmp/t5/instructions.txt' /tmp/t5/seed.sh"
assert "seed.sh has sentinel guard"        "grep -q 'langop-seeded' /tmp/t5/seed.sh"
assert "seed.sh binds run to /workspace"   "grep -q 'opencode run.*--dir /workspace' /tmp/t5/seed.sh"

# ---------------------------------------------------------------------------
# Test 6: no instructions → no seed script (graceful no-op)
# ---------------------------------------------------------------------------
echo "--- Test 6: no instructions means no seed script ---"

set_config << 'EOF'
models:
  claude-sonnet:
    model: claude-sonnet-4-5
    endpoint: http://gateway.default.svc.cluster.local:8000
EOF

mkdir -p /tmp/t6
OPENCODE_CONFIG_DIR=/tmp/t6 \
  node /app/seed-config.mjs > /tmp/t6/out.txt 2>&1
clear_config

assert "no seed.sh without instructions"   "[ ! -f /tmp/t6/seed.sh ]"
assert "no instructions.txt"               "[ ! -f /tmp/t6/instructions.txt ]"
assert "default model still set"           "grep -q 'openai/claude-sonnet-4-5' /tmp/t6/opencode.jsonc"

# ---------------------------------------------------------------------------
# Test 7: AGENT_INSTRUCTIONS env fallback (config.yaml omits instructions)
# ---------------------------------------------------------------------------
echo "--- Test 7: AGENT_INSTRUCTIONS env fallback ---"

mkdir -p /tmp/t7
AGENT_INSTRUCTIONS="Greet the user warmly." \
  MODEL_ENDPOINT=http://gateway.default.svc.cluster.local:8000 \
  LLM_MODEL=claude-sonnet-4-5 \
  OPENCODE_CONFIG_DIR=/tmp/t7 \
  node /app/seed-config.mjs > /tmp/t7/out.txt 2>&1

assert "seed.sh from env fallback"         "[ -f /tmp/t7/seed.sh ]"
assert "instructions.txt from env"         "grep -q 'Greet the user warmly' /tmp/t7/instructions.txt"
assert "seed.sh model from LLM_MODEL"      "grep -q 'openai/claude-sonnet-4-5' /tmp/t7/seed.sh"

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
