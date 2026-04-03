#!/usr/bin/env bash
# =============================================================================
# Claude Code - Build & Install from Source (Profile-based)
#
# Usage:
#   bash scripts/setup.sh                       # build + install with default profile
#   bash scripts/setup.sh -p custom-api         # use a specific profile
#   bash scripts/setup.sh --build               # build only (skip install)
#   bash scripts/setup.sh --install             # install only (skip build)
#   bash scripts/setup.sh --run [args...]       # run directly without building
#   bash scripts/setup.sh --list-profiles       # show available profiles
#   bash scripts/setup.sh --clean               # remove dist/ and node_modules/
#
# Profile files: config/profiles/<name>.json
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST="$ROOT/dist"
PROFILES_DIR="$ROOT/config/profiles"
ENTRY="$ROOT/src/entrypoints/cli.tsx"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}=== $* ===${RESET}\n"; }

# --------------------------------------------------------------------------- #
# Parse args
# --------------------------------------------------------------------------- #
PROFILE_NAME="default"
MODE="full"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--profile)     PROFILE_NAME="$2"; shift 2 ;;
    --build)              MODE="build"; shift ;;
    --install)            MODE="install"; shift ;;
    --run)                MODE="run"; shift ;;
    --proxy)              MODE="proxy"; shift ;;
    --install-litellm)    MODE="install-litellm"; shift ;;
    --list-profiles)      MODE="list"; shift ;;
    --clean)              MODE="clean"; shift ;;
    switch)               MODE="switch"; SWITCH_PROVIDER="${2:-}"; shift 2 2>/dev/null || shift ;;
    model)                MODE="model";  MODEL_OVERRIDE="${2:-}";  shift 2 2>/dev/null || shift ;;
    --help|-h)
      echo "Usage: bash scripts/setup.sh [options]"
      echo ""
      echo "  -p, --profile <name>   Use named profile (default: 'default')"
      echo "  --build                Build dist/cli.js only"
      echo "  --install              Generate launcher + link to PATH only"
      echo "  --run [args]           Run source directly (no build, for dev)"
      echo "  --proxy                Start built-in proxy (proxy/server.ts)"
      echo "  --install-litellm      Install LiteLLM as advanced proxy backend"
      echo "  --list-profiles        Show all available profiles"
      echo "  --clean                Remove dist/ and node_modules/"
      echo "  switch <provider>      Switch AI provider for claude-* models"
      echo "                         Providers: openai | codex | anthropic | gemini | azure | bedrock"
      echo "  model <model-id>       Override model within current provider"
      echo "  model reset            Reset to provider default model"
      echo ""
      echo "Profiles: $PROFILES_DIR/"
      exit 0
      ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

# --------------------------------------------------------------------------- #
# Profile loading
# --------------------------------------------------------------------------- #
load_profile() {
  local profile_file="$PROFILES_DIR/${PROFILE_NAME}.json"

  [[ -f "$profile_file" ]] || die "Profile not found: $profile_file\nRun --list-profiles to see available profiles."

  # Parse JSON with python3 (no jq dependency)
  local py_parse='
import json, sys, os

with open(sys.argv[1]) as f:
    p = json.load(f)

def expand(v):
    return os.path.expandvars(os.path.expanduser(v)) if isinstance(v, str) else v

name        = p.get("name", "default")
bin_name    = p.get("binary", {}).get("name", "claude-local")
config_dir  = expand(p.get("data", {}).get("configDir", "~/.claude-local"))
api_url     = expand(p.get("api", {}).get("baseUrl", ""))
api_key     = expand(p.get("api", {}).get("apiKey", ""))
api_model   = expand(p.get("api", {}).get("model", ""))
extra_env   = p.get("env", {})

print(f"PROFILE_NAME={name}")
print(f"PROFILE_BIN={bin_name}")
print(f"PROFILE_CONFIG_DIR={config_dir}")
print(f"PROFILE_API_URL={api_url}")
print(f"PROFILE_API_KEY={api_key}")
print(f"PROFILE_MODEL={api_model}")

for k, v in extra_env.items():
    print(f"PROFILE_ENV_{k}={v}")
'
  eval "$(python3 -c "$py_parse" "$profile_file")"

  # Surface extra env vars from profile
  PROFILE_EXTRA_ENVS=()
  while IFS= read -r line; do
    if [[ "$line" == PROFILE_ENV_* ]]; then
      local kv="${line#PROFILE_ENV_}"
      PROFILE_EXTRA_ENVS+=("$kv")
    fi
  done < <(python3 -c "$py_parse" "$profile_file")

  ok "Loaded profile: ${BOLD}${PROFILE_NAME}${RESET}"
  log "  Binary name : $PROFILE_BIN"
  log "  Config dir  : $PROFILE_CONFIG_DIR"
  log "  API base URL: ${PROFILE_API_URL:-'(Anthropic default)'}"
  log "  API key     : ${PROFILE_API_KEY:+set}${PROFILE_API_KEY:-'(not set)'}"
  log "  Model       : ${PROFILE_MODEL:-'(default)'}"
}

list_profiles() {
  section "Available Profiles"
  local count=0
  for f in "$PROFILES_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    local name
    name=$(basename "$f" .json)
    local bin_name
    bin_name=$(python3 -c "import json; p=json.load(open('$f')); print(p.get('binary',{}).get('name','?'))" 2>/dev/null || echo "?")
    local desc
    desc=$(python3 -c "import json; p=json.load(open('$f')); print(p.get('binary',{}).get('description',''))" 2>/dev/null || echo "")
    echo -e "  ${CYAN}${name}${RESET}  →  binary: ${BOLD}${bin_name}${RESET}  ${desc}"
    (( count++ )) || true
  done
  echo ""
  echo -e "Create a new profile by copying ${CYAN}config/profiles/default.json${RESET}"
  echo -e "Usage: ${BOLD}bash scripts/setup.sh -p <profile-name>${RESET}"
}

# --------------------------------------------------------------------------- #
# Check API Key is configured
# --------------------------------------------------------------------------- #
check_api_key() {
  # At least one provider key must be available (config file or env var)
  local proxy_cfg="$ROOT/proxy/config.json"
  local litellm_venv="$ROOT/.venv-litellm"

  # Collect all available keys
  local cfg_openai="" cfg_gemini="" cfg_anthropic=""
  if [[ -f "$proxy_cfg" ]]; then
    cfg_openai=$(python3 -c "
import json
try:
    c = json.load(open('$proxy_cfg'))
    print(c.get('providers',{}).get('openai',{}).get('apiKey',''))
except: print('')
" 2>/dev/null || echo "")
    cfg_gemini=$(python3 -c "
import json
try:
    c = json.load(open('$proxy_cfg'))
    print(c.get('providers',{}).get('gemini',{}).get('apiKey',''))
except: print('')
" 2>/dev/null || echo "")
    cfg_anthropic=$(python3 -c "
import json
try:
    c = json.load(open('$proxy_cfg'))
    print(c.get('providers',{}).get('anthropic',{}).get('apiKey',''))
except: print('')
" 2>/dev/null || echo "")
  fi

  # Check if any key is available (config or env)
  local has_key=false
  [[ -n "$cfg_openai" || -n "${OPENAI_API_KEY:-}" ]]     && has_key=true
  [[ -n "$cfg_gemini" || -n "${GEMINI_API_KEY:-}" ]]     && has_key=true
  [[ -n "$cfg_anthropic" || -n "${ANTHROPIC_API_KEY:-}" ]] && has_key=true
  [[ -n "${CODEX_API_KEY:-}" ]]                           && has_key=true
  [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]                       && has_key=true

  if ! $has_key; then
    echo ""
    echo -e "${YELLOW}┌────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${YELLOW}│  ACTION REQUIRED: 未找到任何 API Key                       │${RESET}"
    echo -e "${YELLOW}│                                                             │${RESET}"
    echo -e "${YELLOW}│  至少设置一个（推荐写入 ~/.zshrc 永久生效）：               │${RESET}"
    echo -e "${YELLOW}│    export OPENAI_API_KEY=sk-...        # OpenAI            │${RESET}"
    echo -e "${YELLOW}│    export GEMINI_API_KEY=AI...         # Google Gemini     │${RESET}"
    echo -e "${YELLOW}│    export ANTHROPIC_API_KEY=sk-ant-... # 真实 Anthropic    │${RESET}"
    echo -e "${YELLOW}│                                                             │${RESET}"
    echo -e "${YELLOW}│  或直接写入 proxy/config.json → providers.<name>.apiKey   │${RESET}"
    echo -e "${YELLOW}│                                                             │${RESET}"
    echo -e "${YELLOW}│  配置后重新运行: bash scripts/setup.sh -p custom-api       │${RESET}"
    echo -e "${YELLOW}└────────────────────────────────────────────────────────────┘${RESET}"
    echo ""
    exit 1
  fi

  # Summary
  local using=()
  [[ -n "$cfg_openai" || -n "${OPENAI_API_KEY:-}" ]]       && using+=("OpenAI")
  [[ -n "$cfg_gemini" || -n "${GEMINI_API_KEY:-}" ]]       && using+=("Gemini")
  [[ -n "$cfg_anthropic" || -n "${ANTHROPIC_API_KEY:-}" ]] && using+=("Anthropic")
  [[ -n "${CODEX_API_KEY:-}" ]]                            && using+=("Codex")
  [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]                        && using+=("Bedrock")
  ok "API keys configured: ${using[*]}"
  [[ -d "$litellm_venv" ]] && ok "LiteLLM detected — will be used as proxy backend"
}

# --------------------------------------------------------------------------- #
# Check requirements
# --------------------------------------------------------------------------- #
check_requirements() {
  section "Checking Requirements"

  command -v node &>/dev/null || die "Node.js not found. Install from https://nodejs.org/ (>= 18)"
  local node_major
  node_major=$(node --version | sed 's/v//;s/\..*//')
  (( node_major >= 18 )) || die "Node.js $(node --version) too old. Need >= 18"
  ok "Node.js $(node --version)"

  if ! command -v bun &>/dev/null; then
    warn "Bun not found. Installing..."
    if command -v brew &>/dev/null; then
      brew install oven-sh/bun/bun
    else
      curl -fsSL https://bun.sh/install | bash
      export PATH="$HOME/.bun/bin:$PATH"
    fi
    command -v bun &>/dev/null || die "Bun install failed. See https://bun.sh"
  fi
  ok "Bun $(bun --version)"
}

# --------------------------------------------------------------------------- #
# Install dependencies
# --------------------------------------------------------------------------- #
install_deps() {
  section "Installing Dependencies"
  cd "$ROOT"
  [[ -f package.json ]] || die "package.json not found in $ROOT"
  bun install
  ok "Dependencies installed"
}

# --------------------------------------------------------------------------- #
# Build
# --------------------------------------------------------------------------- #
build_source() {
  section "Building Source → dist/cli.js"

  cd "$ROOT"
  mkdir -p "$DIST"

  log "Entry  : $ENTRY"
  log "Output : $DIST/cli.js"
  log "Polyfills applied:"
  log "  bun:bundle  → polyfills/bun-bundle.ts  (feature() = false)"
  log "  @ant/*      → stubs/@ant/*"
  echo ""

  # Aliases are in bunfig.toml [build.alias] — Bun 1.x CLI has no --alias flag
  # MACRO.* defines must be passed via --define (dotted keys not supported in bunfig.toml)
  local VERSION
  VERSION=$(node -e "try{process.stdout.write(require('$ROOT/package.json').version)}catch(e){process.stdout.write('0.0.0')}")

  bun build "$ENTRY" \
    --outfile "$DIST/cli.js" \
    --target node \
    --format esm \
    --define "MACRO.VERSION=\"${VERSION}\"" \
    --define 'MACRO.BUILD_TIME="source-build"' \
    --define 'MACRO.PACKAGE_URL="https://www.npmjs.com/package/@anthropic-ai/claude-code"' \
    --define 'MACRO.NATIVE_PACKAGE_URL="https://www.npmjs.com/package/@anthropic-ai/claude-code"' \
    --define 'MACRO.ISSUES_EXPLAINER="https://github.com/anthropics/claude-code/issues"' \
    --define 'MACRO.FEEDBACK_CHANNEL="https://github.com/anthropics/claude-code/issues"' \
    --define 'MACRO.VERSION_CHANGELOG="https://github.com/anthropics/claude-code/releases"' \
    2>&1 || die "Build failed. Check the error above."

  # Ensure shebang
  local first
  first=$(head -1 "$DIST/cli.js")
  if [[ "$first" != "#!/usr/bin/env node" ]]; then
    { echo '#!/usr/bin/env node'; cat "$DIST/cli.js"; } > "$DIST/cli.js.tmp"
    mv "$DIST/cli.js.tmp" "$DIST/cli.js"
  fi
  chmod +x "$DIST/cli.js"

  local size_kb
  size_kb=$(du -k "$DIST/cli.js" | cut -f1)
  ok "Built: $DIST/cli.js (${size_kb}KB)"
}

# --------------------------------------------------------------------------- #
# Generate launcher script
# --------------------------------------------------------------------------- #
generate_launcher() {
  local bin_name="$1"
  local config_dir="$2"
  local api_url="$3"
  local api_key="$4"
  local model="$5"

  local launcher="$DIST/${bin_name}"

  {
    echo '#!/usr/bin/env bash'
    echo "# Auto-generated launcher for profile: ${PROFILE_NAME}"
    echo "# Binary name : ${bin_name}"
    echo "# Config dir  : ${config_dir}"
    echo "# Regenerate  : bash scripts/setup.sh -p ${PROFILE_NAME} --install"
    echo ""

    # Config directory (isolates sessions, settings, history from official claude)
    echo "export CLAUDE_CONFIG_DIR=\"${config_dir}\""

    # API endpoint
    [[ -n "$api_url" && "$api_url" != "https://api.anthropic.com" ]] && \
      echo "export ANTHROPIC_BASE_URL=\"${api_url}\""

    # API key
    [[ -n "$api_key" ]] && \
      echo "export ANTHROPIC_API_KEY=\"${api_key}\""

    # Default model
    [[ -n "$model" ]] && \
      echo "export ANTHROPIC_MODEL=\"${model}\""

    # Extra env vars from profile
    for kv in "${PROFILE_EXTRA_ENVS[@]:-}"; do
      [[ -n "$kv" ]] && echo "export ${kv}"
    done

    # Auto-start proxy if ANTHROPIC_BASE_URL points to localhost
    if [[ -n "$api_url" && "$api_url" == http://localhost:* ]]; then
      local proxy_port="${api_url##*:}"
      proxy_port="${proxy_port%%/*}"
      cat << PROXY_BLOCK

# Auto-start proxy if not running
_PROXY_PORT="${proxy_port}"
_PROXY_LOG="\${TMPDIR:-/tmp}/${bin_name}-proxy.log"
_PROXY_PID_FILE="\${TMPDIR:-/tmp}/${bin_name}-proxy.pid"

_start_proxy() {
  local _BUN
  _BUN=\$(command -v bun || echo "/opt/homebrew/bin/bun")
  if [[ ! -x "\$_BUN" ]]; then
    echo "[${bin_name}] Warning: bun not found, cannot auto-start proxy" >&2
    return 1
  fi

  # Check if LiteLLM venv exists and prefer it
  local _LITELLM_VENV="${ROOT}/.venv-litellm"
  if [[ -f "\$_LITELLM_VENV/bin/litellm" && -f "${ROOT}/proxy/litellm.yaml" ]]; then
    echo "[${bin_name}] Starting LiteLLM proxy on port \${_PROXY_PORT}..." >&2
    nohup "\$_LITELLM_VENV/bin/litellm" --config "${ROOT}/proxy/litellm.yaml" --port "\${_PROXY_PORT}" \
      > "\$_PROXY_LOG" 2>&1 &
  else
    echo "[${bin_name}] Starting built-in proxy on port \${_PROXY_PORT}..." >&2
    CLAUDEX_PROVIDER="\${CLAUDEX_PROVIDER:-\${MYAI_PROVIDER:-}}" CLAUDEX_MODEL="\${CLAUDEX_MODEL:-\${MYAI_MODEL:-}}" nohup "\$_BUN" "${ROOT}/proxy/server.ts" --port "\${_PROXY_PORT}" \
      > "\$_PROXY_LOG" 2>&1 &
  fi

  echo \$! > "\$_PROXY_PID_FILE"
  # Wait up to 8s for proxy to be ready
  for _i in 1 2 3 4 5 6 7 8; do
    sleep 1
    curl -sf "http://localhost:\${_PROXY_PORT}/health" > /dev/null 2>&1 && return 0
  done
  echo "[${bin_name}] Warning: proxy did not start in time. Check \$_PROXY_LOG" >&2
}

_restart_proxy() {
  pkill -f "proxy/server.ts|litellm|claudex-proxy" 2>/dev/null || true
  sleep 1
  _start_proxy
}

_doctor() {
  echo "[${bin_name}] doctor"
  command -v node >/dev/null 2>&1 && echo "  node      : ok (\$(node -v))" || echo "  node      : missing"
  command -v bun  >/dev/null 2>&1 && echo "  bun       : ok (\$(bun -v))"  || echo "  bun       : missing"
  command -v curl >/dev/null 2>&1 && echo "  curl      : ok"               || echo "  curl      : missing"
  echo "  provider  : \${CLAUDEX_PROVIDER:-\${MYAI_PROVIDER:-openai}}"
  echo "  model     : \${CLAUDEX_MODEL:-\${MYAI_MODEL:-(provider default)}}"
  if curl -sf "http://localhost:\${_PROXY_PORT}/health" > /dev/null 2>&1; then
    echo "  proxy     : running (port \${_PROXY_PORT})"
  else
    echo "  proxy     : stopped"
  fi
  echo "  log file  : \${_PROXY_LOG}"
}

case "\${1:-}" in
  status)
    echo "[${bin_name}] status"
    echo "  provider  : \${CLAUDEX_PROVIDER:-\${MYAI_PROVIDER:-openai}}"
    echo "  model     : \${CLAUDEX_MODEL:-\${MYAI_MODEL:-(provider default)}}"
    echo "  port      : \${_PROXY_PORT}"
    curl -sf "http://localhost:\${_PROXY_PORT}/health" > /dev/null 2>&1 \
      && echo "  proxy     : running" || echo "  proxy     : stopped"
    echo "  logs      : \${_PROXY_LOG}"
    exit 0
    ;;
  logs)
    [[ -f "\${_PROXY_LOG}" ]] && tail -50 "\${_PROXY_LOG}" || echo "[${bin_name}] no log: \${_PROXY_LOG}"
    exit 0
    ;;
  doctor)
    _doctor
    exit 0
    ;;
  restart)
    echo "[${bin_name}] restarting proxy..."
    _restart_proxy && echo "[${bin_name}] proxy restarted" || echo "[${bin_name}] proxy restart failed"
    exit 0
    ;;
  help|--help|-h)
    echo "${bin_name} status   # proxy/provider/model status"
    echo "${bin_name} logs     # show proxy logs"
    echo "${bin_name} doctor   # diagnostics"
    echo "${bin_name} restart  # restart proxy"
    ;;
esac

if ! curl -sf "http://localhost:\${_PROXY_PORT}/health" > /dev/null 2>&1; then
  _start_proxy
fi
PROXY_BLOCK
    fi

    echo ""
    echo "exec node \"${DIST}/cli.js\" \"\$@\""
  } > "$launcher"

  chmod +x "$launcher"
  ok "Launcher: $launcher"
}

# --------------------------------------------------------------------------- #
# Install (link to PATH)
# --------------------------------------------------------------------------- #
install_binary() {
  section "Installing Binary: ${PROFILE_BIN}"

  [[ -f "$DIST/cli.js" ]] || die "dist/cli.js not found. Run --build first."

  generate_launcher \
    "$PROFILE_BIN" \
    "$PROFILE_CONFIG_DIR" \
    "${PROFILE_API_URL:-}" \
    "${PROFILE_API_KEY:-}" \
    "${PROFILE_MODEL:-}"

  local launcher="$DIST/${PROFILE_BIN}"
  local installed=false

  # Try npm link first (cleanest for Node projects)
  if npm link --silent 2>/dev/null; then
    # npm link uses the bin field in package.json - we need to update it
    python3 - "$ROOT/package.json" "$PROFILE_BIN" <<'EOF'
import json, sys
with open(sys.argv[1]) as f:
    pkg = json.load(f)
pkg["bin"] = {sys.argv[2]: f"./dist/{sys.argv[2]}"}
with open(sys.argv[1], 'w') as f:
    json.dump(pkg, f, indent=2)
    f.write('\n')
EOF
    npm link --silent 2>/dev/null && installed=true
  fi

  if ! $installed; then
    # Fallback: direct symlink to a PATH directory
    local path_dirs=("$HOME/.local/bin" "/usr/local/bin" "$HOME/bin")
    local link_dir=""
    for d in "${path_dirs[@]}"; do
      if echo "$PATH" | tr ':' '\n' | grep -qx "$d"; then
        link_dir="$d"
        break
      fi
    done
    if [[ -z "$link_dir" ]]; then
      link_dir="$HOME/.local/bin"
      mkdir -p "$link_dir"
      warn "Added $link_dir to PATH. Run: export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
    ln -sf "$launcher" "$link_dir/${PROFILE_BIN}"
    ok "Linked: $link_dir/${PROFILE_BIN} → $launcher"
    installed=true
  fi

  echo ""
  ok "Binary '${PROFILE_BIN}' installed."
  log "Config dir: $PROFILE_CONFIG_DIR (isolated from official ~/.claude)"
  [[ -n "${PROFILE_API_URL:-}" && "${PROFILE_API_URL}" != "https://api.anthropic.com" ]] && \
    log "API endpoint: $PROFILE_API_URL"
}

# --------------------------------------------------------------------------- #
# Install LiteLLM (advanced multi-model proxy backend)
# --------------------------------------------------------------------------- #
install_litellm() {
  section "Installing LiteLLM (advanced proxy backend)"

  local venv_dir="$ROOT/.venv-litellm"
  local litellm_cfg="$ROOT/proxy/litellm.yaml"

  command -v python3 &>/dev/null || die "Python 3 not found. Install Python 3.10+ first."
  local py_major
  py_major=$(python3 -c "import sys; print(sys.version_info.major)")
  local py_minor
  py_minor=$(python3 -c "import sys; print(sys.version_info.minor)")
  (( py_major > 3 || (py_major == 3 && py_minor >= 10) )) || \
    die "Python $(python3 --version) too old. Need >= 3.10"
  ok "Python $(python3 --version)"

  # Create Python venv if needed
  if [[ ! -d "$venv_dir" ]]; then
    log "Creating Python venv at $venv_dir..."
    python3 -m venv "$venv_dir" || die "python3 -m venv failed."
  fi

  log "Installing litellm[proxy] (this may take 1-2 minutes)..."
  "$venv_dir/bin/pip" install --quiet --upgrade "litellm[proxy]" || die "pip install litellm failed."
  ok "LiteLLM $("$venv_dir/bin/litellm" --version 2>/dev/null | head -1 || echo 'installed')"

  # Generate litellm.yaml (only if not already customized)
  if [[ ! -f "$litellm_cfg" ]]; then
    log "Generating $litellm_cfg..."
    cat > "$litellm_cfg" << 'YAML'
# LiteLLM Proxy — Claude Code 多模型代理配置
# 文档: https://docs.litellm.ai/docs/proxy/configs
#
# Claude Code 以 Anthropic 格式（/v1/messages）请求本代理，
# LiteLLM 自动转换并路由到下方配置的 provider。
#
# API Keys 通过环境变量传入（推荐写入 ~/.zshrc / ~/.bashrc）：
#   export OPENAI_API_KEY=sk-...              # OpenAI
#   export GEMINI_API_KEY=AI...               # Google Gemini
#   export ANTHROPIC_API_KEY=sk-ant-...       # 真实 Anthropic（可选）
#   export AZURE_API_KEY=...                  # Azure OpenAI
#   export AZURE_API_BASE=https://xxx.openai.azure.com
#   export AWS_ACCESS_KEY_ID=...              # AWS Bedrock
#   export AWS_SECRET_ACCESS_KEY=...
#   export AWS_REGION=us-east-1

litellm_settings:
  drop_params: true   # 忽略 Anthropic 专有参数（OpenAI/Gemini/Bedrock 不接受）

# 模型路由规则（client 发什么 model 名 → 实际调用什么）
# Claude Code 默认发送 claude-* 系列名称
model_list:

  # ── OpenAI ──────────────────────────────────────────────────────────────
  - model_name: "claude-*"        # Claude Code 发的全部 claude-* 走 OpenAI
    litellm_params:
      model: openai/gpt-5.4
      api_key: os.environ/OPENAI_API_KEY
      api_base: os.environ/OPENAI_API_BASE

  - model_name: "gpt-*"
    litellm_params:
      model: openai/gpt-5.4
      api_key: os.environ/OPENAI_API_KEY
      api_base: os.environ/OPENAI_API_BASE

  - model_name: "o1-*"
    litellm_params:
      model: openai/o1
      api_key: os.environ/OPENAI_API_KEY

  - model_name: "o3-*"
    litellm_params:
      model: openai/o3
      api_key: os.environ/OPENAI_API_KEY

  # ── OpenAI Codex ──────────────────────────────────────────────────────────
  # CODEX_API_KEY 独立于 OPENAI_API_KEY；CODEX_API_BASE 用于公司自定义接口
  - model_name: "codex-*"
    litellm_params:
      model: openai/gpt-5.4
      api_key: os.environ/CODEX_API_KEY
      api_base: os.environ/CODEX_API_BASE     # 公司自定义接口，留空则走 api.openai.com

  - model_name: "gpt-5*codex*"
    litellm_params:
      model: openai/gpt-5.4
      api_key: os.environ/CODEX_API_KEY
      api_base: os.environ/CODEX_API_BASE

  # ── Google Gemini ────────────────────────────────────────────────────────
  - model_name: "gemini-*"
    litellm_params:
      model: gemini/gemini-3.1-pro-preview
      api_key: os.environ/GEMINI_API_KEY
      api_base: os.environ/GEMINI_API_BASE

  # ── Azure OpenAI ─────────────────────────────────────────────────────────
  # 设置 AZURE_API_KEY 和 AZURE_API_BASE 后取消注释以下条目
  # - model_name: "azure-gpt-5.4"
  #   litellm_params:
  #     model: azure/gpt-5.4              # azure/<deployment-name>
  #     api_key: os.environ/AZURE_API_KEY
  #     api_base: os.environ/AZURE_API_BASE
  #     api_version: "2024-12-01-preview"

  # ── AWS Bedrock ───────────────────────────────────────────────────────────
  # 设置 AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION 后取消注释
  # - model_name: "bedrock-claude"
  #   litellm_params:
  #     model: bedrock/anthropic.claude-opus-4-6
  #     aws_access_key_id: os.environ/AWS_ACCESS_KEY_ID
  #     aws_secret_access_key: os.environ/AWS_SECRET_ACCESS_KEY
  #     aws_region_name: os.environ/AWS_REGION
  #     aws_bedrock_runtime_endpoint: os.environ/AWS_BEDROCK_ENDPOINT
  #
  # Bedrock 常用模型 ID：
  #   anthropic.claude-opus-4-6-v1                 (Claude Opus 4.6，最强)
  #   anthropic.claude-sonnet-4-6                  (Claude Sonnet 4.6，均衡)
  #   anthropic.claude-3-5-sonnet-20241022-v2:0    (Claude 3.5 Sonnet)
  #   anthropic.claude-3-haiku-20240307-v1:0       (Claude 3 Haiku，速度快)
  #   meta.llama3-70b-instruct-v1:0
  #   mistral.mistral-large-2402-v1:0

  # ── 真实 Anthropic（直连，需要 ANTHROPIC_API_KEY）────────────────────────
  - model_name: "anthropic/claude-*"
    litellm_params:
      model: anthropic/claude-opus-4-6
      api_key: os.environ/ANTHROPIC_API_KEY
      api_base: os.environ/ANTHROPIC_API_BASE

  # ── 兜底：未匹配的请求全走 OpenAI ────────────────────────────────────────
  - model_name: "*"
    litellm_params:
      model: openai/gpt-5.4
      api_key: os.environ/OPENAI_API_KEY
      api_base: os.environ/OPENAI_API_BASE
YAML
    ok "Created: $litellm_cfg"
  else
    warn "Already exists (skipped): $litellm_cfg"
  fi

  echo ""
  echo -e "${GREEN}${BOLD}LiteLLM 安装完成！${RESET}"
  echo ""
  echo -e "  ${BOLD}下一步（如果还没设置）：${RESET}"
  echo -e "  ${CYAN}echo 'export OPENAI_API_KEY=sk-...' >> ~/.zshrc${RESET}"
  echo -e "  ${CYAN}source ~/.zshrc${RESET}"
  echo ""
  echo -e "  ${BOLD}之后直接使用 claudex，代理会自动用 LiteLLM 启动。${RESET}"
  echo ""
  echo -e "  配置文件: ${CYAN}$litellm_cfg${RESET}"
  echo -e "  支持更多模型（Bedrock/Azure/Groq等）参考:"
  echo -e "  ${CYAN}https://docs.litellm.ai/docs/providers${RESET}"
}

# --------------------------------------------------------------------------- #
# Dev mode: run source directly
# --------------------------------------------------------------------------- #
run_dev() {
  section "Dev Mode (source → bun run)"

  cd "$ROOT"
  log "Running: bun run $ENTRY"
  log "Profile: $PROFILE_NAME (env vars applied)"
  echo ""

  # Apply profile env inline
  [[ -n "${PROFILE_CONFIG_DIR:-}" ]] && export CLAUDE_CONFIG_DIR="$PROFILE_CONFIG_DIR"
  [[ -n "${PROFILE_API_URL:-}" && "${PROFILE_API_URL:-}" != "https://api.anthropic.com" ]] && \
    export ANTHROPIC_BASE_URL="$PROFILE_API_URL"
  [[ -n "${PROFILE_API_KEY:-}" ]] && export ANTHROPIC_API_KEY="$PROFILE_API_KEY"
  [[ -n "${PROFILE_MODEL:-}" ]] && export ANTHROPIC_MODEL="$PROFILE_MODEL"

  for kv in "${PROFILE_EXTRA_ENVS[@]:-}"; do
    [[ -n "$kv" ]] && export "$kv"
  done

  # bun doesn't support --alias at runtime, use bunfig.toml aliases
  exec bun run "$ENTRY" "${EXTRA_ARGS[@]}"
}

# --------------------------------------------------------------------------- #
# Switch provider (updates CLAUDEX_PROVIDER in ~/.zshrc / ~/.bashrc)
# --------------------------------------------------------------------------- #
do_switch() {
  local provider="${SWITCH_PROVIDER:-}"
  local valid_providers=("openai" "codex" "anthropic" "gemini" "azure" "bedrock")

  if [[ -z "$provider" ]]; then
    echo -e "${BOLD}当前 provider:${RESET} ${CYAN}${CLAUDEX_PROVIDER:-${MYAI_PROVIDER:-（未设置，使用 config.json 路由规则）}}${RESET}"
    echo ""
    echo -e "用法: bash scripts/setup.sh switch <provider>"
    echo -e "可用 provider:"
    for p in "${valid_providers[@]}"; do
      printf "  %-12s" "$p"
      case "$p" in
        openai)    echo "→ OpenAI GPT-4.1 等" ;;
        codex)     echo "→ OpenAI Codex 系列（自定义 API 地址）" ;;
        anthropic) echo "→ Anthropic Claude 官方 API" ;;
        gemini)    echo "→ Google Gemini" ;;
        azure)     echo "→ Azure OpenAI" ;;
        bedrock)   echo "→ AWS Bedrock" ;;
      esac
    done
    echo ""
    echo -e "当前 config.json 默认路由:"
    python3 -c "
import json
cfg = json.load(open('$ROOT/proxy/config.json'))
for r in cfg.get('routes', []):
    if r['pattern'] == 'claude-*':
        print(f'  claude-* → {r[\"provider\"]}')
        break
" 2>/dev/null || true
    exit 0
  fi

  # Validate
  local valid=false
  for p in "${valid_providers[@]}"; do
    [[ "$p" == "$provider" ]] && valid=true && break
  done
  $valid || die "不支持的 provider: $provider\n可用: ${valid_providers[*]}"

  section "切换 Provider → $provider"

  # 1. Update CLAUDEX_PROVIDER in shell rc files
  local shell_rc=""
  if [[ -f "$HOME/.zshrc" ]]; then
    shell_rc="$HOME/.zshrc"
  elif [[ -f "$HOME/.bashrc" ]]; then
    shell_rc="$HOME/.bashrc"
  fi

  if [[ -n "$shell_rc" ]]; then
    # Remove old provider lines if exists
    sed -i.bak '/^export MYAI_PROVIDER=/d;/^export CLAUDEX_PROVIDER=/d' "$shell_rc" && rm -f "${shell_rc}.bak"
    echo "export CLAUDEX_PROVIDER=\"$provider\"" >> "$shell_rc"
    ok "已写入 $shell_rc: export CLAUDEX_PROVIDER=\"$provider\""
  fi

  # 2. Export for current session
  export CLAUDEX_PROVIDER="$provider"

  # 3. Restart proxy in background to pick up the new env var
  local builtin_cfg="$ROOT/proxy/config.json"
  local proxy_port
  proxy_port=$(python3 -c "import json; print(json.load(open('$builtin_cfg')).get('port', 4315))" 2>/dev/null || echo "4315")

  if lsof -ti tcp:"$proxy_port" &>/dev/null; then
    log "重启代理（端口 $proxy_port）以生效..."
    kill "$(lsof -ti tcp:$proxy_port)" 2>/dev/null || true
    sleep 1
  fi

  CLAUDEX_PROVIDER="$provider" CLAUDEX_MODEL="${CLAUDEX_MODEL:-${MYAI_MODEL:-}}" /opt/homebrew/bin/bun "$ROOT/proxy/server.ts" \
    --config "$builtin_cfg" --port "$proxy_port" \
    >> /tmp/claudex-proxy.log 2>&1 &
  sleep 1

  if lsof -ti tcp:"$proxy_port" &>/dev/null; then
    ok "代理已重启，当前 provider: ${BOLD}$provider${RESET}"
  else
    warn "代理重启失败，请手动运行: bash scripts/setup.sh --proxy"
  fi

  echo ""
  echo -e "${CYAN}生效范围:${RESET}"
  echo -e "  当前终端: ${GREEN}已生效${RESET}（CLAUDEX_PROVIDER=$provider）"
  echo -e "  新终端:   ${GREEN}已生效${RESET}（写入了 $shell_rc）"
  echo -e "  代理:     ${GREEN}已重启${RESET}"
  echo ""
  echo -e "  切回默认路由: ${BOLD}bash scripts/setup.sh switch openai${RESET}（或其他）"
}

# --------------------------------------------------------------------------- #
# Model override
# --------------------------------------------------------------------------- #
do_model() {
  local model="${MODEL_OVERRIDE:-}"

  if [[ -z "$model" ]]; then
    echo -e "${BOLD}当前 model:${RESET} ${CYAN}${CLAUDEX_MODEL:-${MYAI_MODEL:-（未设置，使用各 provider 默认模型）}}${RESET}"
    echo ""
    echo -e "用法: bash scripts/setup.sh model <model-id>"
    echo -e "      bash scripts/setup.sh model reset  （清除，恢复默认）"
    echo ""
    echo -e "常用示例:"
    echo "  openai    : gpt-5.4 / gpt-5.4-mini"
    echo "  anthropic : claude-opus-4-6 / claude-sonnet-4-6"
    echo "  gemini    : gemini-3.1-pro-preview / gemini-3.1-flash-lite-preview"
    echo "  bedrock   : anthropic.claude-opus-4-6"
    exit 0
  fi

  local shell_rc=""
  if [[ -f "$HOME/.zshrc" ]]; then shell_rc="$HOME/.zshrc"
  elif [[ -f "$HOME/.bashrc" ]]; then shell_rc="$HOME/.bashrc"
  fi

  if [[ "$model" == "reset" ]]; then
    [[ -n "$shell_rc" ]] && sed -i.bak '/^export MYAI_MODEL=/d;/^export CLAUDEX_MODEL=/d' "$shell_rc" && rm -f "${shell_rc}.bak"
    unset CLAUDEX_MODEL
    ok "CLAUDEX_MODEL 已清除，将使用 provider 默认模型"
  else
    if [[ -n "$shell_rc" ]]; then
      sed -i.bak '/^export MYAI_MODEL=/d;/^export CLAUDEX_MODEL=/d' "$shell_rc" && rm -f "${shell_rc}.bak"
      echo "export CLAUDEX_MODEL=\"$model\"" >> "$shell_rc"
      ok "已写入 $shell_rc: export CLAUDEX_MODEL=\"$model\""
    fi
    export CLAUDEX_MODEL="$model"
    echo ""
    echo -e "${CYAN}当前 model 已设置为:${RESET} ${BOLD}$model${RESET}"
  fi

  # Restart proxy to pick up the new model
  local proxy_port
  proxy_port=$(python3 -c "import json; print(json.load(open('$ROOT/proxy/config.json')).get('port', 4315))" 2>/dev/null || echo "4315")
  if lsof -ti tcp:"$proxy_port" &>/dev/null; then
    log "重启代理以生效..."
    kill "$(lsof -ti tcp:$proxy_port)" 2>/dev/null || true
    sleep 1
    CLAUDEX_PROVIDER="${CLAUDEX_PROVIDER:-${MYAI_PROVIDER:-}}" CLAUDEX_MODEL="${CLAUDEX_MODEL:-${MYAI_MODEL:-}}" \
      /opt/homebrew/bin/bun "$ROOT/proxy/server.ts" \
      --config "$ROOT/proxy/config.json" --port "$proxy_port" \
      >> /tmp/claudex-proxy.log 2>&1 &
    sleep 1
    lsof -ti tcp:"$proxy_port" &>/dev/null && ok "代理已重启" || warn "代理重启失败，请手动运行: bash scripts/setup.sh --proxy"
  fi
  echo ""
}

# --------------------------------------------------------------------------- #
# Clean
# --------------------------------------------------------------------------- #
do_clean() {
  section "Cleaning"
  cd "$ROOT"
  rm -rf dist/ node_modules/
  ok "Removed dist/ and node_modules/"
}

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
print_summary() {
  section "Done"
  echo -e "${BOLD}${PROFILE_BIN}${RESET} is installed."
  echo ""
  echo -e "${CYAN}Run:${RESET}"
  echo -e "  ${BOLD}${PROFILE_BIN}${RESET}                    # interactive mode"
  echo -e "  ${BOLD}${PROFILE_BIN} --version${RESET}          # verify"
  echo -e "  ${BOLD}${PROFILE_BIN} -p 'task'${RESET}          # non-interactive"
  echo ""
  echo -e "${CYAN}Data directory (isolated):${RESET}"
  echo -e "  $PROFILE_CONFIG_DIR"
  echo ""
  echo -e "${CYAN}Rebuild after source changes:${RESET}"
  echo -e "  bash scripts/setup.sh -p ${PROFILE_NAME} --build --install"
  echo ""
  echo -e "${CYAN}Manage profiles:${RESET}"
  echo -e "  bash scripts/setup.sh --list-profiles"
  echo -e "  edit config/profiles/${PROFILE_NAME}.json"
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${BLUE}║   Claude Code — Build from Source        ║${RESET}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${RESET}"
echo ""

case "$MODE" in
  list)
    list_profiles
    exit 0
    ;;
  switch)
    do_switch
    exit 0
    ;;
  model)
    do_model
    exit 0
    ;;
  clean)
    do_clean
    exit 0
    ;;
  install-litellm)
    install_litellm
    exit 0
    ;;
  proxy)
    section "Starting Multi-Model Proxy"
    cd "$ROOT"
    litellm_venv="$ROOT/.venv-litellm"
    litellm_cfg="$ROOT/proxy/litellm.yaml"
    builtin_cfg="$ROOT/proxy/config.json"
    proxy_port=4000

    if [[ -f "$builtin_cfg" ]]; then
      proxy_port=$(python3 -c "import json; print(json.load(open('$builtin_cfg')).get('port', 4000))" 2>/dev/null || echo "4000")
    fi

    if [[ -f "$litellm_venv/bin/litellm" && -f "$litellm_cfg" ]]; then
      log "Backend : LiteLLM"
      log "Config  : $litellm_cfg"
      log "Port    : $proxy_port"
      echo ""
      exec "$litellm_venv/bin/litellm" \
        --config "$litellm_cfg" \
        --port "$proxy_port" \
        ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
    else
      [[ -f "$builtin_cfg" ]] || die "proxy/config.json not found. Run from project root."
      log "Backend : built-in (proxy/server.ts)"
      log "Config  : $builtin_cfg"
      log "Port    : $proxy_port"
      log "Tip     : run --install-litellm for more model support"
      echo ""
      exec /opt/homebrew/bin/bun "$ROOT/proxy/server.ts" --config "$builtin_cfg" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
    fi
    ;;
esac

# All other modes need a profile loaded
load_profile

case "$MODE" in
  full)
    check_api_key
    check_requirements
    install_deps
    build_source
    install_binary
    print_summary
    ;;
  build)
    check_requirements
    install_deps
    build_source
    ;;
  install)
    install_binary
    print_summary
    ;;
  run)
    check_requirements
    install_deps
    run_dev
    ;;
esac
