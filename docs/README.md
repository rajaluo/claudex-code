# claudex User Guide

[English](./README.md) | [中文](./README.zh.md)

---

> Legal notice: `claudex` is a community-maintained project and **NOT an official Anthropic product**. Please read `LEGAL.md` and `NOTICE.md` in the repository root before distribution.

## Quick Start

After installation, use `claudex` instead of the official `claude` command. Other usage remains the same.

### One-line Network Install (GitHub Release)

```bash
curl -fsSL https://github.com/rajaluo/claudex-code/releases/latest/download/install.sh | bash
```

The installer auto-detects platform (`darwin/linux + arm64/x64`) and downloads the matching package.

```bash
claudex                      # interactive mode
claudex -p "analyze this code"
claudex help                 # management commands
```

---

## Step 1: Set API Keys

Add variables in `~/.zshrc` (or `~/.bashrc`), then run `source ~/.zshrc`:

| Provider | Environment Variables | Where to get |
|----------|------------------------|--------------|
| OpenAI | `OPENAI_API_KEY=sk-...` | [platform.openai.com](https://platform.openai.com/api-keys) |
| Codex (custom endpoint) | `CODEX_API_KEY=sk-...`<br>`CODEX_API_BASE=https://your.api.com/v1` | Internal / third-party |
| Google Gemini | `GEMINI_API_KEY=AI...` | [aistudio.google.com](https://aistudio.google.com/app/apikey) |
| Anthropic | `ANTHROPIC_API_KEY=sk-ant-...` | [console.anthropic.com](https://console.anthropic.com/) |
| Azure OpenAI | `AZURE_API_KEY=xxx`<br>`AZURE_OPENAI_ENDPOINT=https://{resource}.openai.azure.com`<br>`AZURE_OPENAI_DEPLOYMENT=gpt-5.4` | Azure Portal |
| AWS Bedrock | `AWS_ACCESS_KEY_ID=xxx`<br>`AWS_SECRET_ACCESS_KEY=xxx`<br>`AWS_REGION=us-east-1` | AWS IAM (`AWS_REGION` only for role-based runtimes) |

### Optional: Override Provider API URLs (official defaults if unset)

| Provider | URL override env var | Default |
|----------|----------------------|---------|
| OpenAI | `OPENAI_API_BASE` | `https://api.openai.com/v1` |
| Codex | `CODEX_API_BASE` | `https://api.openai.com/v1` |
| Gemini | `GEMINI_API_BASE` | official Gemini API |
| Anthropic | `ANTHROPIC_API_BASE` | `https://api.anthropic.com` |
| Azure OpenAI | `AZURE_OPENAI_ENDPOINT` | none (required) |
| Bedrock | `AWS_BEDROCK_ENDPOINT` | official AWS endpoint |

Rule: **environment variables have highest priority**. If an override is set, claudex uses it; otherwise it falls back to official/default endpoints.

---

## Step 2: Switch Provider

```bash
claudex switch openai      # OpenAI (default)
claudex switch codex       # Codex / OpenAI-compatible endpoint
claudex switch anthropic   # Anthropic Claude
claudex switch gemini      # Google Gemini
claudex switch azure       # Azure OpenAI
claudex switch bedrock     # AWS Bedrock
claudex switch             # show current setting and all options
```

The switch takes effect immediately (proxy auto-restarts) and is persisted to `~/.zshrc`.

## Step 3 (Optional): Switch Model Within Same Provider

Each provider has a default model. To use another model from the same provider:

```bash
claudex model
claudex model gpt-5.4-mini
claudex model claude-sonnet-4-6
claudex model claude-opus-4-6
claudex model gemini-3.1-pro-preview
claudex model gemini-3.1-flash-lite-preview
claudex model anthropic.claude-opus-4-6
claudex model reset
```

This is persisted to `~/.zshrc`, and proxy auto-restarts.

---

## Default Models

| Provider  | Default model | Notes |
|-----------|---------------|-------|
| openai    | `gpt-5.4` | flagship; use `gpt-5.4-mini` for faster/cheaper |
| codex     | `gpt-5.4` | OpenAI-compatible custom endpoint |
| anthropic | `claude-opus-4-6` | flagship; `claude-sonnet-4-6` for speed/cost |
| gemini    | `gemini-3.1-pro-preview` | flagship; `gemini-3.1-flash-lite-preview` for speed |
| azure     | `gpt-5.4` | should match your Azure deployment name |
| bedrock   | `anthropic.claude-opus-4-6` | full Bedrock model ID |

### Permanent Model Override With `CLAUDEX_MODEL`

```bash
echo 'export CLAUDEX_MODEL=gpt-5.4-mini' >> ~/.zshrc && source ~/.zshrc
claudex restart
```

Common examples:

```bash
export CLAUDEX_MODEL=gpt-5.4-mini
export CLAUDEX_MODEL=claude-sonnet-4-6
export CLAUDEX_MODEL=claude-opus-4-6
export CLAUDEX_MODEL=gemini-3.1-pro-preview
export CLAUDEX_MODEL=gemini-3.1-flash-lite-preview
export CLAUDEX_MODEL=anthropic.claude-opus-4-6
```

To reset provider default model: `unset CLAUDEX_MODEL` and remove that line from your shell rc.

### One-off Provider+Model Override

Use `provider/model` prefix (bypasses routing rules for that request):

```text
openai/gpt-5.4
openai/gpt-5.4-mini
openai/o3
anthropic/claude-opus-4-6
anthropic/claude-sonnet-4-6
gemini/gemini-3.1-pro-preview
gemini/gemini-3.1-flash-lite-preview
codex/gpt-5.4
bedrock/anthropic.claude-opus-4-6
bedrock/meta.llama3-70b-instruct-v1:0
azure/my-gpt-deployment
```

In Claude Code sessions, enter the above with `/model`.

---

## Common Scenarios

### Company-wide Codex endpoint

```bash
export CODEX_API_KEY=sk-your-company-key
export CODEX_API_BASE=https://ai.your-company.com/v1
claudex switch codex
```

### AWS Bedrock in IAM role environments (EC2/ECS)

```bash
export AWS_REGION=us-east-1
claudex switch bedrock
```

### Azure OpenAI

```bash
export AZURE_API_KEY=xxxxxxxxxxxxxxxx
export AZURE_OPENAI_ENDPOINT=https://my-resource.openai.azure.com
export AZURE_OPENAI_DEPLOYMENT=gpt-5.4
claudex switch azure
```

### Using multiple providers

Only one provider is active at a time. For temporary testing:

```bash
CLAUDEX_PROVIDER=gemini claudex -p "hello"
```

or set model with provider prefix:

```text
gemini/gemini-3.1-pro-preview
```

---

## Status & Troubleshooting

```bash
claudex status
claudex logs
claudex doctor
claudex restart
```

Common issues:

| Symptom | Fix |
|---------|-----|
| `API Error` / no response | verify API key, e.g. `echo $OPENAI_API_KEY` |
| switch/model not effective | run `claudex restart` or open a new terminal |
| proxy fails to start | check `claudex logs` |
| reset provider | `claudex switch openai` |
| reset model | `claudex model reset` |

---

## Skills & Marketplace Compatibility

`claudex` uses the same data directory as official Claude Code (`~/.claude`), so:

- Marketplace skills work out of the box.
- `CLAUDE.md`, project memory, and history are shared.
- Official `claude` and custom `claudex` can coexist (different command names).

---

## Data Directory

| Command | Config directory | Skills directory |
|---------|------------------|------------------|
| `claudex` | `~/.claude/` | `~/.claude/skills/` |
