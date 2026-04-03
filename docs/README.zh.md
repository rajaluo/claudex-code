# claudex 使用指南

[English](./README.md) | [中文](./README.zh.md)

---

> 法律声明：`claudex` 是社区维护项目，**非官方 Anthropic 产品**，与 Anthropic 无隶属关系。发布与分发前请先阅读仓库根目录的 `LEGAL.md` 与 `NOTICE.md`。

## 快速开始

安装完成后，用 `claudex` 代替官方 `claude` 命令。其他所有用法完全一致。

### 一键网络安装（GitHub Release）

```bash
curl -fsSL https://github.com/rajaluo/claudex-code/releases/latest/download/install.sh | bash
```

安装脚本会自动识别你的系统（darwin/linux + arm64/x64）并下载对应包。

```bash
claudex                        # 启动交互模式
claudex -p "帮我分析这段代码"   # 非交互执行任务
claudex help                   # 查看管理命令
```

---

## 第一步：设置 API Key

在 `~/.zshrc`（或 `~/.bashrc`）里加一行，然后 `source ~/.zshrc`：

| 服务商 | 环境变量 | 获取地址 |
|--------|----------|---------|
| OpenAI | `OPENAI_API_KEY=sk-...` | [platform.openai.com](https://platform.openai.com/api-keys) |
| Codex（自定义地址） | `CODEX_API_KEY=sk-...`<br>`CODEX_API_BASE=https://your.api.com/v1` | 公司内部 / 第三方 |
| Google Gemini | `GEMINI_API_KEY=AI...` | [aistudio.google.com](https://aistudio.google.com/app/apikey) |
| Anthropic 官方 | `ANTHROPIC_API_KEY=sk-ant-...` | [console.anthropic.com](https://console.anthropic.com/) |
| Azure OpenAI | `AZURE_API_KEY=xxx`<br>`AZURE_OPENAI_ENDPOINT=https://{resource}.openai.azure.com`<br>`AZURE_OPENAI_DEPLOYMENT=gpt-5.4` | Azure Portal |
| AWS Bedrock | `AWS_ACCESS_KEY_ID=xxx`<br>`AWS_SECRET_ACCESS_KEY=xxx`<br>`AWS_REGION=us-east-1` | AWS IAM（EC2/ECS 环境只需 `AWS_REGION`） |

### 可选：覆盖各厂商 API URL（不设置就走官方）

| 服务商 | URL 覆盖环境变量 | 默认值 |
|--------|------------------|--------|
| OpenAI | `OPENAI_API_BASE` | `https://api.openai.com/v1` |
| Codex | `CODEX_API_BASE` | `https://api.openai.com/v1` |
| Gemini | `GEMINI_API_BASE` | 官方 Gemini API |
| Anthropic | `ANTHROPIC_API_BASE` | `https://api.anthropic.com` |
| Azure OpenAI | `AZURE_OPENAI_ENDPOINT` | 无（必须提供） |
| Bedrock | `AWS_BEDROCK_ENDPOINT` | AWS 官方 endpoint |

> 规则：**环境变量优先级最高**。如果配置了覆盖 URL，就用覆盖值；不配则使用官方默认地址（或配置文件默认）。

---

## 第二步：切换模型服务商

```bash
claudex switch openai      # OpenAI（默认）
claudex switch codex       # Codex 或兼容 OpenAI 的自定义接口
claudex switch anthropic   # Anthropic 官方 Claude
claudex switch gemini      # Google Gemini
claudex switch azure       # Azure OpenAI
claudex switch bedrock     # AWS Bedrock
claudex switch             # 查看当前设置及所有选项
```

切换后立即生效（代理自动重启），同时写入 `~/.zshrc` 让新终端也生效。

## 第三步（可选）：切换同 Provider 内的具体模型

每个 provider 都有默认模型（见下表）。如果想用同 provider 的其他模型，用 `model` 子命令：

```bash
claudex model                        # 查看当前 model 及所有示例
claudex model gpt-5.4-mini           # 切换到更快/更省钱的 OpenAI 模型
claudex model claude-sonnet-4-6      # 切换到 Anthropic Sonnet（较快版）
claudex model claude-opus-4-6        # 切换到 Anthropic Opus（旗舰版）
claudex model gemini-3.1-pro-preview # 切换到 Gemini 旗舰
claudex model gemini-3.1-flash-lite-preview  # 切换到 Gemini 快速版
claudex model anthropic.claude-opus-4-6      # Bedrock 旗舰
claudex model reset                  # 恢复 provider 默认模型
```

设置后写入 `~/.zshrc`，新终端也生效，代理自动重启。

---

## 指定具体模型

### 各 Provider 最新默认模型

| Provider  | 默认模型 | 备注 |
|-----------|----------|------|
| openai    | `gpt-5.4` | 旗舰；更快/更省钱用 `gpt-5.4-mini` |
| codex     | `gpt-5.4` | 兼容 OpenAI API 的自定义接口 |
| anthropic | `claude-opus-4-6` | 旗舰；较快/省钱用 `claude-sonnet-4-6` |
| gemini    | `gemini-3.1-pro-preview` | 旗舰；较快用 `gemini-3.1-flash-lite-preview` |
| azure     | `gpt-5.4` | 填你在 Azure 创建的**部署名** |
| bedrock   | `anthropic.claude-opus-4-6` | Bedrock 完整 model ID |

### 永久切换到同 Provider 的其他模型

用 `CLAUDEX_MODEL` 环境变量覆盖默认模型（对当前激活的 provider 生效）：

```bash
# 写入 ~/.zshrc，永久生效
echo 'export CLAUDEX_MODEL=gpt-5.4-mini' >> ~/.zshrc && source ~/.zshrc
claudex restart   # 重启代理让配置生效
```

```bash
# 常用示例
export CLAUDEX_MODEL=gpt-5.4-mini           # OpenAI 更快/更省钱
export CLAUDEX_MODEL=claude-sonnet-4-6      # Anthropic 较快版
export CLAUDEX_MODEL=claude-opus-4-6        # Anthropic 旗舰版
export CLAUDEX_MODEL=gemini-3.1-pro-preview # Gemini 旗舰
export CLAUDEX_MODEL=gemini-3.1-flash-lite-preview  # Gemini 快速版
export CLAUDEX_MODEL=anthropic.claude-opus-4-6      # Bedrock 旗舰
```

> 清除 `CLAUDEX_MODEL` 则恢复默认：`unset CLAUDEX_MODEL`（同时删除 ~/.zshrc 里那行）

### 单次临时指定 provider + 模型

在模型名前加 `provider/` 前缀，**完全绕过路由规则**，仅当次对话生效：

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

在 Claude Code 会话里通过 `/model` 命令输入上述格式即可。

---

## 常用场景

### 场景 1：公司统一 Codex 接口

```bash
# ~/.zshrc
export CODEX_API_KEY=sk-your-company-key
export CODEX_API_BASE=https://ai.your-company.com/v1

# 切换
claudex switch codex
```

### 场景 2：AWS Bedrock（IAM Role 环境，如 EC2/ECS）

```bash
# ~/.zshrc — 只需要区域，不需要 Key（用实例 Role）
export AWS_REGION=us-east-1

claudex switch bedrock
```

### 场景 3：Azure OpenAI

```bash
# ~/.zshrc
export AZURE_API_KEY=xxxxxxxxxxxxxxxx
export AZURE_OPENAI_ENDPOINT=https://my-resource.openai.azure.com
export AZURE_OPENAI_DEPLOYMENT=gpt-5.4   # 你在 Azure 创建的部署名

claudex switch azure
```

### 场景 4：同时用多个服务商

同一会话只能激活一个 provider。如果要临时测试其他 provider：

```bash
# 当前默认是 openai，临时用一下 gemini
CLAUDEX_PROVIDER=gemini claudex -p "你好"

# 或在模型名加前缀（在 Claude Code 会话内设置）
gemini/gemini-3.1-pro-preview
```

---

## 查看状态与排障

```bash
claudex status          # 查看当前 provider、model、代理状态、数据目录
claudex logs            # 查看代理日志（出错时看这里）
claudex doctor          # 一键诊断环境与代理状态
claudex restart         # 手动重启代理
```

**常见问题：**

| 现象 | 解决 |
|------|------|
| `API Error` 或无响应 | 先检查 API Key 是否设置：`echo $OPENAI_API_KEY` |
| 切换后没生效 | `claudex restart` 重启代理，或新开终端 |
| 代理启动失败 | `claudex logs` 查看具体报错 |
| 想恢复默认路由 | `claudex switch openai` |
| 想恢复默认模型 | `claudex model reset` |

---

## Skills 与 Marketplace

`claudex` 使用与官方 `claude` 相同的配置目录 `~/.claude`，因此：

- **Marketplace 安装的 Skills 完全兼容**，无需重新安装
- **CLAUDE.md、项目记忆、会话历史**与官方共享
- 官方 `claude` 和 `claudex` 可以同时安装，互不干扰（命令名不同）

---

## 数据目录

| 命令 | 配置目录 | Skills 目录 |
|---------|------------------|------------------|
| `claudex` | `~/.claude/` | `~/.claude/skills/` |
