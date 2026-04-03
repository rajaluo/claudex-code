# 安装使用指南

> **关键点：** 统一使用 `claudex` 命令，配置目录为 `~/.claude/`，可与官方 `claude` 共存。

## 前置要求

| 工具 | 版本 | 说明 |
|------|------|------|
| Node.js | >= 18 | [nodejs.org](https://nodejs.org/) |
| Bun | >= 1.1 | 没有会自动安装 |
| Python | >= 3.10 | 仅 LiteLLM 场景需要 |

---

## 安装（2 步）

### 第 1 步：设置至少一个 API Key

```bash
echo 'export OPENAI_API_KEY=sk-...' >> ~/.zshrc
source ~/.zshrc
```

也可以使用 Gemini / Anthropic / Azure / Bedrock / Codex，见下方环境变量速查。

### 第 2 步：一键安装

```bash
bash scripts/setup.sh -p claudex
```

---

## 使用

```bash
claudex
claudex -p "帮我写一个冒泡排序"
claudex help
claudex doctor
```

代理会自动后台启动，无需手动起服务。

---

## 切换 Provider 与模型

```bash
claudex switch openai
claudex switch anthropic
claudex switch gemini
claudex switch azure
claudex switch bedrock
claudex switch codex
```

同一 provider 内切换模型：

```bash
claudex model gpt-5.4-mini
claudex model claude-sonnet-4-6
claudex model gemini-3.1-flash-lite-preview
claudex model reset
```

---

## 环境变量速查

```bash
# OpenAI
export OPENAI_API_KEY=sk-...
export OPENAI_API_BASE=https://api.openai.com/v1              # 可选覆盖

# Codex
export CODEX_API_KEY=sk-...
export CODEX_API_BASE=https://your-company-api.example.com/v1 # 可选覆盖

# Gemini
export GEMINI_API_KEY=AI...
export GEMINI_API_BASE=https://generativelanguage.googleapis.com # 可选覆盖

# Anthropic
export ANTHROPIC_API_KEY=sk-ant-...
export ANTHROPIC_API_BASE=https://api.anthropic.com           # 可选覆盖

# Azure OpenAI
export AZURE_API_KEY=xxx
export AZURE_OPENAI_ENDPOINT=https://{resource}.openai.azure.com
export AZURE_OPENAI_DEPLOYMENT=gpt-5.4
export AZURE_OPENAI_API_VERSION=2024-02-01                    # 可选覆盖

# AWS Bedrock
export AWS_ACCESS_KEY_ID=xxx
export AWS_SECRET_ACCESS_KEY=xxx
export AWS_REGION=us-east-1
export AWS_BEDROCK_ENDPOINT=                                   # 可选覆盖（私有网络/代理场景）
```

规则：不设置 URL 覆盖变量时，默认走官方地址；设置后优先使用覆盖地址。

---

## 常见问题

命令找不到：

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

查看代理日志：

```bash
cat /tmp/claudex-proxy.log
```

改了代理配置后重启：

```bash
claudex restart
```

一键诊断：

```bash
claudex doctor
```

---

## 目录说明

| 项目 | 路径 |
|------|------|
| 命令 | `claudex` |
| 配置/历史/会话 | `~/.claude/` |
| Skills | `~/.claude/skills/` |
| 项目记忆 | `项目根目录/CLAUDE.md` |
