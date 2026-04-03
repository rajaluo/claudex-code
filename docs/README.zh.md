# claudex 使用指南

[English](./README.md) | [中文](./README.zh.md)

---

> 法律声明：`claudex` 是社区维护项目，**非官方 Anthropic 产品**。发布与分发前请先阅读仓库根目录的 `LEGAL.md` 与 `NOTICE.md`。

## 快速开始

```bash
curl -fsSL https://github.com/rajaluo/claudex-code/releases/latest/download/install.sh | bash
```

```bash
claudex
claudex -p "帮我分析这段代码"
claudex help
```

## 配置 API Key

在 `~/.zshrc`（或 `~/.bashrc`）中配置并执行 `source ~/.zshrc`：

- `OPENAI_API_KEY`
- `CODEX_API_KEY`（可配 `CODEX_API_BASE`）
- `GEMINI_API_KEY`
- `ANTHROPIC_API_KEY`
- `AZURE_API_KEY` + `AZURE_OPENAI_ENDPOINT` + `AZURE_OPENAI_DEPLOYMENT`
- `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` + `AWS_REGION`

## 切换 Provider

```bash
claudex switch openai
claudex switch codex
claudex switch anthropic
claudex switch gemini
claudex switch azure
claudex switch bedrock
claudex switch
```

## 切换同厂商模型

```bash
claudex model
claudex model gpt-5.4-mini
claudex model claude-sonnet-4-6
claudex model gemini-3.1-flash-lite-preview
claudex model reset
```

## 常用排障

```bash
claudex status
claudex logs
claudex doctor
claudex restart
```

## 说明

- 默认英文文档：`docs/README.md`
- 完整英文版副本：`docs/README.en.md`
