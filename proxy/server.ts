#!/usr/bin/env bun
/**
 * Multi-model proxy server for Claude Code.
 * Accepts Anthropic Messages API format, routes to OpenAI / Gemini / Anthropic / Azure.
 *
 * Usage:
 *   bun proxy/server.ts [--config proxy/config.json] [--port 4000]
 */

import { createServer, type IncomingMessage, type ServerResponse } from 'http'
import { readFileSync, existsSync } from 'fs'
import { resolve, dirname } from 'path'
import { fileURLToPath } from 'url'

// Default config embedded at compile time — no external config.json required.
// Users can override by passing --config <path> or placing config.json next to binary.
import defaultConfig from './config.json'

// -------------------------------------------------------------------------- //
// Config
// -------------------------------------------------------------------------- //

let configPath: string | null = null
let portOverride: number | null = null

for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i] === '--config') configPath = resolve(process.argv[++i])
  if (process.argv[i] === '--port') portOverride = parseInt(process.argv[++i])
}

// If no --config flag, check for config.json next to binary (for dev / override)
if (!configPath) {
  const __dir = import.meta.url.startsWith('file://')
    ? dirname(fileURLToPath(import.meta.url))
    : dirname(process.execPath)
  const adjacent = resolve(__dir, 'config.json')
  if (existsSync(adjacent)) configPath = adjacent
}

interface ProviderConfig {
  apiKey?: string
  baseUrl?: string
  apiVersion?: string
  // Azure-specific
  endpoint?: string
  deployment?: string
  // Bedrock-specific
  region?: string
  model?: string
}

interface ProxyConfig {
  port: number
  providers: Record<string, ProviderConfig>
  routes: Array<{ pattern: string; provider: string }>
  defaultModel: Record<string, string>
}

const config: ProxyConfig = configPath
  ? JSON.parse(readFileSync(configPath, 'utf8'))
  : (defaultConfig as unknown as ProxyConfig)
const PORT = portOverride ?? config.port ?? 4315

// Resolve API key: config file takes precedence, falls back to env var
function resolveKey(provider: string): string {
  const fromConfig = config.providers[provider]?.apiKey
  if (fromConfig) return fromConfig
  const envMap: Record<string, string> = {
    openai:    'OPENAI_API_KEY',
    gemini:    'GEMINI_API_KEY',
    anthropic: 'ANTHROPIC_API_KEY',
    azure:     'AZURE_API_KEY',
    bedrock:   '',  // Bedrock uses AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
    codex:     'CODEX_API_KEY',
  }
  return process.env[envMap[provider] ?? ''] ?? ''
}

// -------------------------------------------------------------------------- //
// Model routing
// -------------------------------------------------------------------------- //

function resolveProvider(model: string): string {
  // Explicit provider prefixes take priority
  if (model.startsWith('bedrock/'))   return 'bedrock'
  if (model.startsWith('azure/'))     return 'azure'
  if (model.startsWith('anthropic/')) return 'anthropic'
  if (model.startsWith('openai/'))    return 'openai'
  if (model.startsWith('gemini/'))    return 'gemini'
  if (model.startsWith('codex/'))     return 'codex'

  // CLAUDEX_PROVIDER env var overrides the claude-* routing rule.
  // Keep MYAI_PROVIDER as backward-compatible fallback.
  const envProvider = process.env.CLAUDEX_PROVIDER || process.env.MYAI_PROVIDER
  if (envProvider && model.startsWith('claude-')) return envProvider

  for (const route of config.routes) {
    const pattern = route.pattern.replace(/\*/g, '.*')
    if (new RegExp(`^${pattern}$`).test(model)) return route.provider
  }
  return 'openai'
}

// Strip provider prefix from model name (e.g. "bedrock/anthropic.claude-3-5-sonnet" → "anthropic.claude-3-5-sonnet")
function stripProviderPrefix(model: string): string {
  return model.replace(/^(bedrock|azure|anthropic|openai|gemini|codex)\//, '')
}

function hasProviderPrefix(model: string): boolean {
  return /^(bedrock|azure|anthropic|openai|gemini|codex)\//.test(model)
}

// Resolve the actual model name to send to the provider.
// Priority:
// 1) explicit provider/model prefix from request (single-call override)
// 2) CLAUDEX_MODEL env (global override)
// 3) model name from request (if not a generic claude-*)
// 4) config defaultModel
function resolveModel(requestModel: string, provider: string): string {
  // Explicit provider/model prefix should always win for one-off overrides.
  if (hasProviderPrefix(requestModel)) return stripProviderPrefix(requestModel)

  // CLAUDEX_MODEL env var: always wins (lets user override without editing config)
  // Keep MYAI_MODEL as backward-compatible fallback.
  const envModel = process.env.CLAUDEX_MODEL || process.env.MYAI_MODEL
  if (envModel) return envModel

  // If request already carries a concrete model name (not a generic claude-* stub), keep it
  const stripped = stripProviderPrefix(requestModel)
  if (!stripped.startsWith('claude-')) return stripped

  // Fallback to per-provider default from config
  return config.defaultModel?.[provider] ?? stripped
}

// -------------------------------------------------------------------------- //
// Anthropic types (subset)
// -------------------------------------------------------------------------- //

interface AnthropicMessage { role: 'user' | 'assistant'; content: ContentBlock[] | string }
interface TextBlock { type: 'text'; text: string }
interface ImageBlock { type: 'image'; source: { type: string; media_type: string; data: string } }
interface ToolUseBlock { type: 'tool_use'; id: string; name: string; input: unknown }
interface ToolResultBlock { type: 'tool_result'; tool_use_id: string; content: string | ContentBlock[] }
type ContentBlock = TextBlock | ImageBlock | ToolUseBlock | ToolResultBlock

interface AnthropicRequest {
  model: string
  messages: AnthropicMessage[]
  system?: string | SystemBlock[]
  max_tokens?: number
  temperature?: number
  tools?: AnthropicTool[]
  stream?: boolean
}

interface SystemBlock { type: 'text'; text: string }
interface AnthropicTool { name: string; description?: string; input_schema: unknown }

// -------------------------------------------------------------------------- //
// Helpers: content block utilities
// -------------------------------------------------------------------------- //

function blocksToText(content: ContentBlock[] | string): string {
  if (typeof content === 'string') return content
  return content
    .filter((b): b is TextBlock => b.type === 'text')
    .map(b => b.text)
    .join('')
}

function systemToText(system?: string | SystemBlock[]): string {
  if (!system) return ''
  if (typeof system === 'string') return system
  return system.filter(b => b.type === 'text').map(b => b.text).join('\n')
}

// -------------------------------------------------------------------------- //
// OpenAI-compatible format: shared message builder + response parser
// (used by both OpenAI and Azure providers)
// -------------------------------------------------------------------------- //

async function callOpenAICompat(
  req: AnthropicRequest,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  client: any,
  overrideModel?: string,
): Promise<Response> {

  const messages: OpenAI.Chat.ChatCompletionMessageParam[] = []
  const systemText = systemToText(req.system)
  if (systemText) messages.push({ role: 'system', content: systemText })

  for (const msg of req.messages) {
    if (typeof msg.content === 'string') {
      messages.push({ role: msg.role, content: msg.content })
      continue
    }

    if (msg.role === 'user') {
      const parts: OpenAI.Chat.ChatCompletionContentPart[] = []
      const toolResults: OpenAI.Chat.ChatCompletionToolMessageParam[] = []

      for (const block of msg.content) {
        if (block.type === 'text') {
          parts.push({ type: 'text', text: block.text })
        } else if (block.type === 'image') {
          parts.push({
            type: 'image_url',
            image_url: { url: `data:${block.source.media_type};base64,${block.source.data}` },
          })
        } else if (block.type === 'tool_result') {
          const content = typeof block.content === 'string' ? block.content : blocksToText(block.content)
          toolResults.push({ role: 'tool', tool_call_id: block.tool_use_id, content })
        }
      }

      if (toolResults.length) {
        messages.push(...toolResults)
      } else {
        messages.push({ role: 'user', content: parts.length === 1 && parts[0].type === 'text' ? parts[0].text : parts })
      }
    } else {
      // assistant
      const toolCalls: OpenAI.Chat.ChatCompletionMessageToolCall[] = []
      let textContent = ''

      for (const block of msg.content) {
        if (block.type === 'text') textContent += block.text
        if (block.type === 'tool_use') {
          toolCalls.push({
            id: block.id,
            type: 'function',
            function: { name: block.name, arguments: JSON.stringify(block.input) },
          })
        }
      }

      messages.push({
        role: 'assistant',
        content: textContent || null,
        ...(toolCalls.length ? { tool_calls: toolCalls } : {}),
      })
    }
  }

  const tools: OpenAI.Chat.ChatCompletionTool[] | undefined = req.tools?.map(t => ({
    type: 'function' as const,
    function: { name: t.name, description: t.description ?? '', parameters: t.input_schema as Record<string, unknown> },
  }))

  const rawModel = overrideModel ?? req.model
  const model = resolveModel(rawModel, 'openai')

  const completion = await client.chat.completions.create({
    model,
    messages,
    max_tokens: req.max_tokens,
    temperature: req.temperature,
    ...(tools?.length ? { tools, tool_choice: 'auto' } : {}),
    stream: false,
  })

  const choice = completion.choices[0]
  const responseContent: ContentBlock[] = []

  if (choice.message.content) {
    responseContent.push({ type: 'text', text: choice.message.content })
  }
  if (choice.message.tool_calls) {
    for (const tc of choice.message.tool_calls) {
      responseContent.push({
        type: 'tool_use',
        id: tc.id,
        name: tc.function.name,
        input: JSON.parse(tc.function.arguments || '{}'),
      })
    }
  }

  const stopReason = choice.finish_reason === 'tool_calls' ? 'tool_use'
    : choice.finish_reason === 'length' ? 'max_tokens' : 'end_turn'

  return new Response(JSON.stringify({
    id: completion.id,
    type: 'message',
    role: 'assistant',
    model: completion.model,
    content: responseContent,
    stop_reason: stopReason,
    usage: {
      input_tokens: completion.usage?.prompt_tokens ?? 0,
      output_tokens: completion.usage?.completion_tokens ?? 0,
    },
  }), { headers: { 'Content-Type': 'application/json' } })
}

// -------------------------------------------------------------------------- //
// OpenAI provider
// -------------------------------------------------------------------------- //

async function callOpenAI(req: AnthropicRequest): Promise<Response> {
  const prov = config.providers.openai
  const apiKey = resolveKey('openai')
  if (!apiKey) throw new Error('OpenAI API key not set. Add to proxy/config.json or set OPENAI_API_KEY env var.')
  const baseURL = process.env.OPENAI_API_BASE || prov?.baseUrl || 'https://api.openai.com/v1'
  const { OpenAI } = await import('openai')
  const client = new OpenAI({ apiKey, baseURL })
  return callOpenAICompat(req, client)
}

// -------------------------------------------------------------------------- //
// Azure OpenAI provider
// -------------------------------------------------------------------------- //

async function callAzure(req: AnthropicRequest): Promise<Response> {
  const prov = config.providers.azure ?? {}
  const apiKey = resolveKey('azure')
  const endpoint = process.env.AZURE_OPENAI_ENDPOINT || prov.endpoint
  const explicitDeployment = req.model.startsWith('azure/') ? stripProviderPrefix(req.model) : ''
  const deployment = explicitDeployment
    || process.env.CLAUDEX_MODEL
    || process.env.MYAI_MODEL
    || prov.deployment
    || process.env.AZURE_OPENAI_DEPLOYMENT
    || config.defaultModel?.azure
    || 'gpt-5.4'

  if (!apiKey) throw new Error('Azure API key not set. Set AZURE_API_KEY env var.')
  if (!endpoint) throw new Error('Azure endpoint not set. Set AZURE_OPENAI_ENDPOINT env var (e.g. https://xxx.openai.azure.com).')

  const { AzureOpenAI } = await import('openai')
  const client = new AzureOpenAI({
    apiKey,
    endpoint,
    deployment,
    apiVersion: process.env.AZURE_OPENAI_API_VERSION || prov.apiVersion || '2024-02-01',
  })
  return callOpenAICompat(req, client, deployment)
}

// -------------------------------------------------------------------------- //
// Codex provider  (OpenAI-compatible, separate key + configurable base URL)
// -------------------------------------------------------------------------- //

async function callCodex(req: AnthropicRequest): Promise<Response> {
  const prov = config.providers.codex
  const apiKey = resolveKey('codex')
  if (!apiKey) throw new Error('Codex API key not set. Set CODEX_API_KEY env var.')

  const baseURL = process.env.CODEX_API_BASE || prov?.baseUrl || 'https://api.openai.com/v1'

  const { OpenAI } = await import('openai')
  const client = new OpenAI({ apiKey, baseURL })
  const defaultModel = resolveModel(req.model, 'codex')
  return callOpenAICompat(req, client, defaultModel)
}

// -------------------------------------------------------------------------- //
// AWS Bedrock provider  (Converse API — supports all Bedrock models)
// -------------------------------------------------------------------------- //

async function callBedrock(req: AnthropicRequest): Promise<Response> {
  const prov = config.providers.bedrock ?? {}
  const region = prov.region ?? process.env.AWS_REGION ?? 'us-east-1'
  const endpoint = process.env.AWS_BEDROCK_ENDPOINT || undefined

  // Determine actual Bedrock model ID
  const rawModel = stripProviderPrefix(req.model)
  const explicitModelId = req.model.startsWith('bedrock/') ? stripProviderPrefix(req.model) : ''
  const modelId = explicitModelId
    || process.env.CLAUDEX_MODEL
    || process.env.MYAI_MODEL
    || (rawModel.includes('.') ? rawModel : '')                  // already a Bedrock model ID
    || prov.model
    || config.defaultModel?.bedrock
    || 'anthropic.claude-opus-4-6'

  const { BedrockRuntimeClient, ConverseCommand } = await import('@aws-sdk/client-bedrock-runtime')
  const client = new BedrockRuntimeClient({ region, ...(endpoint ? { endpoint } : {}) })

  // Convert Anthropic messages → Bedrock Converse format
  type BedrockContent =
    | { text: string }
    | { image: { format: string; source: { bytes: Uint8Array } } }
    | { toolUse: { toolUseId: string; name: string; input: unknown } }
    | { toolResult: { toolUseId: string; content: Array<{ text: string }>; status: 'success' | 'error' } }

  const bedrockMessages = req.messages.map(msg => {
    if (typeof msg.content === 'string') {
      return { role: msg.role, content: [{ text: msg.content }] }
    }

    const content: BedrockContent[] = []
    for (const block of msg.content) {
      if (block.type === 'text') {
        content.push({ text: block.text })
      } else if (block.type === 'image') {
        content.push({
          image: {
            format: block.source.media_type.split('/')[1] ?? 'jpeg',
            source: { bytes: Buffer.from(block.source.data, 'base64') },
          },
        })
      } else if (block.type === 'tool_use') {
        content.push({ toolUse: { toolUseId: block.id, name: block.name, input: block.input } })
      } else if (block.type === 'tool_result') {
        const text = typeof block.content === 'string' ? block.content : blocksToText(block.content)
        content.push({
          toolResult: {
            toolUseId: block.tool_use_id,
            content: [{ text }],
            status: 'success',
          },
        })
      }
    }
    return { role: msg.role, content }
  })

  const systemText = systemToText(req.system)
  const tools = req.tools?.map(t => ({
    toolSpec: {
      name: t.name,
      description: t.description ?? '',
      inputSchema: { json: t.input_schema },
    },
  }))

  const command = new ConverseCommand({
    modelId,
    messages: bedrockMessages as Parameters<typeof ConverseCommand.prototype.constructor>[0]['messages'],
    ...(systemText ? { system: [{ text: systemText }] } : {}),
    ...(tools?.length ? { toolConfig: { tools } } : {}),
    inferenceConfig: {
      maxTokens: req.max_tokens,
      ...(req.temperature !== undefined ? { temperature: req.temperature } : {}),
    },
  })

  const result = await client.send(command)

  const responseContent: ContentBlock[] = []
  for (const block of result.output?.message?.content ?? []) {
    if ('text' in block && block.text) {
      responseContent.push({ type: 'text', text: block.text })
    } else if ('toolUse' in block && block.toolUse) {
      responseContent.push({
        type: 'tool_use',
        id: block.toolUse.toolUseId ?? '',
        name: block.toolUse.name ?? '',
        input: block.toolUse.input ?? {},
      })
    }
  }

  const stopReasonMap: Record<string, string> = {
    end_turn: 'end_turn',
    tool_use: 'tool_use',
    max_tokens: 'max_tokens',
    stop_sequence: 'stop_sequence',
  }

  return new Response(JSON.stringify({
    id: `bedrock-${Date.now()}`,
    type: 'message',
    role: 'assistant',
    model: modelId,
    content: responseContent,
    stop_reason: stopReasonMap[result.stopReason ?? ''] ?? 'end_turn',
    usage: {
      input_tokens: result.usage?.inputTokens ?? 0,
      output_tokens: result.usage?.outputTokens ?? 0,
    },
  }), { headers: { 'Content-Type': 'application/json' } })
}

// -------------------------------------------------------------------------- //
// Gemini provider
// -------------------------------------------------------------------------- //

async function callGemini(req: AnthropicRequest): Promise<Response> {
  const prov = config.providers.gemini ?? {}
  const apiKey = resolveKey('gemini')
  if (!apiKey) throw new Error('Gemini API key not set. Add to proxy/config.json or set GEMINI_API_KEY env var.')
  const baseURL = process.env.GEMINI_API_BASE || prov.baseUrl
  const model = resolveModel(req.model, 'gemini')

  // If a custom Gemini-compatible endpoint is provided, use REST directly.
  // Otherwise, use the official Google SDK + official endpoint.
  if (baseURL) {
    const systemText = systemToText(req.system)
    const contents = req.messages.map(msg => {
      const text = typeof msg.content === 'string' ? msg.content : blocksToText(msg.content as ContentBlock[])
      return {
        role: msg.role === 'assistant' ? 'model' : 'user',
        parts: [{ text }],
      }
    })
    const normalizedBase = baseURL.replace(/\/+$/, '')
    const resp = await fetch(`${normalizedBase}/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(apiKey)}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        contents,
        generationConfig: {
          maxOutputTokens: req.max_tokens,
          ...(req.temperature !== undefined ? { temperature: req.temperature } : {}),
        },
        ...(systemText ? { systemInstruction: { parts: [{ text: systemText }] } } : {}),
      }),
    })

    if (!resp.ok) {
      const detail = await resp.text().catch(() => '')
      throw new Error(`Gemini API error (${resp.status}): ${detail || resp.statusText}`)
    }

    const data = await resp.json() as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>
      usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number }
    }
    const text = data.candidates?.[0]?.content?.parts?.map(p => p.text ?? '').join('') ?? ''
    return new Response(JSON.stringify({
      id: `gemini-${Date.now()}`,
      type: 'message',
      role: 'assistant',
      model,
      content: [{ type: 'text', text }],
      stop_reason: 'end_turn',
      usage: {
        input_tokens: data.usageMetadata?.promptTokenCount ?? 0,
        output_tokens: data.usageMetadata?.candidatesTokenCount ?? 0,
      },
    }), { headers: { 'Content-Type': 'application/json' } })
  }

  const { GoogleGenAI } = await import('@google/genai')
  const ai = new GoogleGenAI({ apiKey })

  const systemText = systemToText(req.system)

  type GeminiRole = 'user' | 'model'
  const contents: Array<{ role: GeminiRole; parts: Array<{ text: string }> }> = []

  for (const msg of req.messages) {
    const text = typeof msg.content === 'string' ? msg.content : blocksToText(msg.content as ContentBlock[])
    const role: GeminiRole = msg.role === 'assistant' ? 'model' : 'user'
    contents.push({ role, parts: [{ text }] })
  }

  const result = await ai.models.generateContent({
    model,
    contents,
    config: {
      ...(systemText ? { systemInstruction: systemText } : {}),
      maxOutputTokens: req.max_tokens,
      temperature: req.temperature,
    },
  })

  const text = result.text ?? ''

  return new Response(JSON.stringify({
    id: `gemini-${Date.now()}`,
    type: 'message',
    role: 'assistant',
    model,
    content: [{ type: 'text', text }],
    stop_reason: 'end_turn',
    usage: {
      input_tokens: result.usageMetadata?.promptTokenCount ?? 0,
      output_tokens: result.usageMetadata?.candidatesTokenCount ?? 0,
    },
  }), { headers: { 'Content-Type': 'application/json' } })
}

// -------------------------------------------------------------------------- //
// Anthropic pass-through provider
// -------------------------------------------------------------------------- //

async function callAnthropic(req: AnthropicRequest, rawHeaders: Record<string, string>): Promise<Response> {
  const prov = config.providers.anthropic
  const baseUrl = process.env.ANTHROPIC_API_BASE || prov?.baseUrl || 'https://api.anthropic.com'
  const apiKey = resolveKey('anthropic') || rawHeaders['x-api-key'] || rawHeaders['authorization']?.replace('Bearer ', '')

  const resp = await fetch(`${baseUrl}/v1/messages`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'anthropic-version': '2023-06-01',
      'x-api-key': apiKey ?? '',
    },
    body: JSON.stringify(req),
  })
  return resp
}

// -------------------------------------------------------------------------- //
// HTTP server
// -------------------------------------------------------------------------- //

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((res, rej) => {
    let data = ''
    req.on('data', chunk => (data += chunk))
    req.on('end', () => res(data))
    req.on('error', rej)
  })
}

function sendError(res: ServerResponse, status: number, message: string): void {
  res.writeHead(status, { 'Content-Type': 'application/json' })
  res.end(JSON.stringify({ type: 'error', error: { type: 'proxy_error', message } }))
}

const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
  // Health check (also handle HEAD for SDK connectivity probes)
  if (req.url === '/health' || req.url === '/' || req.url === '//') {
    if (req.method === 'HEAD') {
      res.writeHead(200, { 'Content-Length': '0' })
      res.end()
      return
    }
    res.writeHead(200)
    res.end(JSON.stringify({ status: 'ok', port: PORT }))
    return
  }

  // Allow HEAD/OPTIONS on any path (connectivity probes)
  if (req.method === 'HEAD' || req.method === 'OPTIONS') {
    res.writeHead(200, { 'Content-Length': '0', 'Access-Control-Allow-Origin': '*' })
    res.end()
    return
  }

  // Normalize URL: strip double leading slashes and query params for route matching
  const normalizedUrl = (req.url || '').replace(/^\/\/+/, '/').split('?')[0]
  if (normalizedUrl !== '/v1/messages' || req.method !== 'POST') {
    sendError(res, 404, `Not found: ${req.method} ${req.url}`)
    return
  }

  let body: string
  try { body = await readBody(req) } catch {
    sendError(res, 400, 'Failed to read request body'); return
  }

  let anthropicReq: AnthropicRequest
  try { anthropicReq = JSON.parse(body) } catch {
    sendError(res, 400, 'Invalid JSON body'); return
  }

  const headers: Record<string, string> = {}
  for (const [k, v] of Object.entries(req.headers)) {
    if (typeof v === 'string') headers[k.toLowerCase()] = v
  }

  const provider = resolveProvider(anthropicReq.model)
  console.log(`[proxy] ${new Date().toISOString()} model=${anthropicReq.model} → provider=${provider}`)

  try {
    let providerResp: Response

    switch (provider) {
      case 'openai':    providerResp = await callOpenAI(anthropicReq); break
      case 'codex':     providerResp = await callCodex(anthropicReq); break
      case 'azure':     providerResp = await callAzure(anthropicReq); break
      case 'bedrock':   providerResp = await callBedrock(anthropicReq); break
      case 'gemini':    providerResp = await callGemini(anthropicReq); break
      case 'anthropic': providerResp = await callAnthropic(anthropicReq, headers); break
      default:
        sendError(res, 400, `Unknown provider: ${provider}`); return
    }

    const responseBody = await providerResp.text()
    res.writeHead(providerResp.status, {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
    })
    res.end(responseBody)
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error(`[proxy] Error:`, msg)
    sendError(res, 500, msg)
  }
})

server.listen(PORT, '127.0.0.1', () => {
  console.log(`\n[proxy] Multi-model proxy running on http://localhost:${PORT}`)
  console.log(`[proxy] Config: ${configPath}`)
  console.log(`[proxy] Routes:`)
  for (const route of config.routes) {
    console.log(`         ${route.pattern.padEnd(20)} → ${route.provider}`)
  }
  console.log()
})

server.on('error', (err) => {
  console.error('[proxy] Server error:', err)
  process.exit(1)
})
