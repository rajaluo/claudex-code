# 发布与分发（无源码）

## 1) GitHub Releases（二进制）

### 先把改造后的代码上传到 GitHub

```bash
# 1) 初始化并绑定远端（已存在仓库可跳过 init）
git init
git remote add origin git@github.com:your-org/claudex.git

# 2) 提交
git add .
git commit -m "release: prepare claudex distribution"

# 3) 推送主分支
git branch -M main
git push -u origin main
```

### 构建

```bash
# 当前机器目标
bash scripts/release.sh --version 1.0.0

# 全兼容矩阵
bash scripts/release.sh --version 1.0.0 --all-targets
```

产物示例：

- `release/claudex-1.0.0-darwin-arm64.tar.gz`
- `release/claudex-1.0.0-darwin-x64.tar.gz`
- `release/claudex-1.0.0-linux-x64.tar.gz`
- `release/claudex-1.0.0-linux-arm64.tar.gz`

### 发布

方式 A（网页）：

1. 在 GitHub 页面创建 tag：`v1.0.0`  
2. 新建 Release，上传 4 个 tar.gz  
3. 在 release notes 写清安装命令与变更

方式 B（命令行，推荐）：

```bash
# 安装并登录 gh
gh auth login

# 创建 tag 并推送
git tag v1.0.0
git push origin v1.0.0

# 创建 release 并上传产物
gh release create v1.0.0 \
  release/claudex-1.0.0-darwin-arm64.tar.gz \
  release/claudex-1.0.0-darwin-x64.tar.gz \
  release/claudex-1.0.0-linux-x64.tar.gz \
  release/claudex-1.0.0-linux-arm64.tar.gz \
  --title "claudex v1.0.0" \
  --notes "Initial public release"
```

用户安装（示例）：

```bash
tar -xzf claudex-1.0.0-darwin-arm64.tar.gz
bash claudex-1.0.0-darwin-arm64/install.sh
```

## 2) 包管理分发

### npm（已接入）

第一次发布前准备：

```bash
# 1) 注册并登录 npm
npm login

# 2) 确认包名可用（或改成你的组织名）
npm view claudex-code version
# 如果返回 404 表示可用；若已被占用，改 scripts/release.sh 里的包名
```

```bash
bash scripts/release.sh --version 1.0.0 --npm
```

会产出并发布 `claudex-code`，命令名为 `claudex`。

用户安装：

```bash
npm i -g claudex-code
claudex --help
```

后续升级发布：

```bash
# 版本号务必递增（例如 1.0.1）
bash scripts/release.sh --version 1.0.1 --npm
```

### Homebrew（建议）

建议新建 tap 仓库：`your-org/homebrew-claudex`，添加 Formula：

```ruby
class Claudex < Formula
  desc "Claude Code with multi-model proxy"
  homepage "https://github.com/your-org/claudex"
  version "1.0.0"
  url "https://github.com/your-org/claudex/releases/download/v#{version}/claudex-#{version}-darwin-arm64.tar.gz"
  sha256 "REPLACE_WITH_SHA256"

  def install
    bin.install "claudex"
    bin.install "claudex-proxy"
    bin.install "claudex-cli.js"
    doc.install "README.md"
  end
end
```

用户安装：

```bash
brew tap your-org/claudex
brew install claudex
```

## 3) 发布检查清单

- `claudex status/logs/doctor` 可用
- `claudex switch` / `claudex model` 可用
- 默认 provider/model 符合文档
- `README.md` 与实际命令一致
- 四平台包可解压并执行 `install.sh`
