/**
 * opencode-adapter init container
 *
 * Bridges the language-operator config injection model to opencode's native
 * config format. Reads /etc/agent/config.yaml (injected by the operator) and
 * translates models and tools into /etc/opencode/opencode.jsonc.
 *
 * The config file is always overwritten — it is operator-managed configuration,
 * not user state (unlike openclaw where the JSON config holds runtime state).
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs'
import { parse as parseYaml } from 'yaml'

const outputDir = process.env.OPENCODE_CONFIG_DIR ?? '/etc/opencode'
const outputFile = `${outputDir}/opencode.jsonc`

mkdirSync(outputDir, { recursive: true })

// -------------------------------------------------------------------
// Read /etc/agent/config.yaml (operator-injected)
// -------------------------------------------------------------------
let operatorConfig = null
const operatorConfigPath = '/etc/agent/config.yaml'
if (existsSync(operatorConfigPath)) {
  try {
    operatorConfig = parseYaml(readFileSync(operatorConfigPath, 'utf8')) ?? {}
    console.log('Read operator config from /etc/agent/config.yaml')
  } catch (err) {
    console.warn(`Failed to parse /etc/agent/config.yaml: ${err.message}`)
  }
}

// -------------------------------------------------------------------
// Build provider config from config.yaml models section.
// Fall back to MODEL_ENDPOINT / LLM_MODEL env vars if absent.
// -------------------------------------------------------------------
const configModels = operatorConfig?.models ?? {}
const provider = {}

// The first registered model id becomes the default for the seeded run and the
// web UI. Provider key is always "openai" (see below), so the qualified id is
// `openai/<modelId>`.
let defaultModelId = null

// LiteLLM exposes an OpenAI-compatible API, so we always use "openai" as the
// provider key regardless of what the CRD models are named. All models are
// aggregated under the single gateway endpoint.

if (Object.keys(configModels).length > 0) {
  // Primary source: config.yaml models section
  // All models share the same LiteLLM gateway — use the first endpoint found.
  const models = {}
  let gatewayEndpoint = null

  for (const [crdName, model] of Object.entries(configModels)) {
    if (!model.endpoint) {
      console.warn(`Model '${crdName}' has no endpoint — skipping`)
      continue
    }
    gatewayEndpoint ??= model.endpoint
    const modelId = model.model ?? crdName
    defaultModelId ??= modelId
    models[modelId] = {}
    console.log(`Registered model '${modelId}' via gateway ${model.endpoint}`)
  }

  if (gatewayEndpoint) {
    const baseURL = gatewayEndpoint.replace(/\/+$/, '') + '/v1'
    provider['openai'] = {
      options: {
        baseURL,
        apiKey: 'sk-langop-proxy',  // placeholder; LiteLLM proxy handles real auth
      },
      models,
    }
  }
} else {
  // Fallback: zip MODEL_ENDPOINT + LLM_MODEL env vars
  const endpoints = (process.env.MODEL_ENDPOINT ?? '').split(',').map(s => s.trim()).filter(Boolean)
  const modelNames = (process.env.LLM_MODEL ?? '').split(',').map(s => s.trim()).filter(Boolean)

  if (endpoints.length === 0) {
    console.warn('MODEL_ENDPOINT is not set and config.yaml has no models — seeding without provider config')
  } else {
    // All models share the same LiteLLM gateway — use the first endpoint.
    const models = {}
    for (let i = 0; i < modelNames.length; i++) {
      models[modelNames[i]] = {}
    }
    const baseURL = endpoints[0].replace(/\/+$/, '') + '/v1'
    provider['openai'] = {
      options: {
        baseURL,
        apiKey: 'sk-langop-proxy',
      },
      models: Object.keys(models).length > 0 ? models : undefined,
    }
    defaultModelId = modelNames[0] ?? null
    console.log(`Configured openai provider → ${baseURL} (models: ${modelNames.join(', ') || 'none'})`)
  }
}

// -------------------------------------------------------------------
// Build MCP server config from config.yaml tools section
// -------------------------------------------------------------------
const configTools = operatorConfig?.tools ?? {}
const mcp = {}

for (const [toolName, tool] of Object.entries(configTools)) {
  if (!tool.endpoint) {
    console.warn(`Tool '${toolName}' has no endpoint — skipping`)
    continue
  }
  if (!tool.endpoint.startsWith('http://') && !tool.endpoint.startsWith('https://')) {
    console.warn(`Tool '${toolName}' endpoint '${tool.endpoint}' is not an HTTP URL — skipping`)
    continue
  }
  mcp[toolName] = { type: 'remote', url: tool.endpoint }
  console.log(`Configured MCP server '${toolName}' → ${tool.endpoint}`)
}

// -------------------------------------------------------------------
// Assemble and write opencode.jsonc
// -------------------------------------------------------------------
const config = {
  autoupdate: false,
}

if (Object.keys(provider).length > 0) {
  config.provider = provider
}

// Default model for the seeded run and for blank sessions started in the UI, so
// neither requires a manual model pick. Always "openai/<id>" (single gateway).
const defaultModel = defaultModelId ? `openai/${defaultModelId}` : null
if (defaultModel) {
  config.model = defaultModel
}

if (Object.keys(mcp).length > 0) {
  config.mcp = mcp
}

writeFileSync(outputFile, JSON.stringify(config, null, 2))
console.log(`Wrote opencode config to ${outputFile}`)

// -------------------------------------------------------------------
// Emit the startup seed script + instructions, so the agent evaluates
// its instructions as the first prompt of a session on first launch.
//
// opencode web never sends a prompt on its own — it opens a blank session.
// The main container backgrounds seed.sh (passing the local server URL); the
// script waits for the server, then `opencode run --attach` creates a session
// under /workspace seeded with the instructions, which the UI then opens into.
//
// Idempotent via a sentinel on the /workspace PVC: evaluated once per workspace,
// so pod restarts/reschedules don't spawn duplicate sessions.
// -------------------------------------------------------------------
const instructions = operatorConfig?.instructions ?? process.env.AGENT_INSTRUCTIONS ?? ''
const agentName = operatorConfig?.agent?.name ?? process.env.AGENT_NAME ?? 'agent'

if (instructions.trim() && defaultModel) {
  const instructionsFile = `${outputDir}/instructions.txt`
  const seedScript = `${outputDir}/seed.sh`

  writeFileSync(instructionsFile, instructions)

  // Only the model id and title (agent name) are interpolated — both come from
  // operator-controlled config, never free-form user text. The instructions
  // themselves flow purely through the stdin redirect below, so they never
  // touch the argv or the script body (robust to large, multi-line, quoted
  // markdown; no ARG_MAX limit, no escaping).
  const title = `${agentName} instructions`.replace(/'/g, "'\\''")
  const model = defaultModel.replace(/'/g, "'\\''")
  const script = `#!/bin/sh
# Generated by opencode-adapter. Seeds the agent's instructions as the first
# prompt of a session, once per workspace. $1 = opencode server base URL.
SENTINEL=/workspace/.langop-seeded
[ -f "$SENTINEL" ] && exit 0
[ -f ${instructionsFile} ] || exit 0
i=0
while [ "$i" -lt 60 ]; do
  # --dir sets the remote project directory; opencode run ignores the shell cwd
  # when attaching, so the session must be bound to /workspace explicitly (the
  # pre-seeded project the web UI opens into) rather than the default global one.
  if opencode run --attach "$1" --dir /workspace --model '${model}' --title '${title}' < ${instructionsFile}; then
    touch "$SENTINEL"
    exit 0
  fi
  i=$((i + 1))
  sleep 2
done
echo "opencode-adapter: seed run did not succeed after retries" >&2
exit 0
`
  writeFileSync(seedScript, script)
  console.log(`Wrote instructions seed → ${seedScript} (model ${defaultModel})`)
} else if (instructions.trim() && !defaultModel) {
  console.warn('Instructions present but no model configured — skipping instructions seed')
}
