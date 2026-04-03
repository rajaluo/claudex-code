#!/usr/bin/env bash
# =============================================================================
# Claude Code (claudex) — Release Packaging
#
# Builds a self-contained release that users can install WITHOUT source code.
# Only requirement on the target machine: Node.js >= 18
#
# Usage:
#   bash scripts/release.sh                     # build release tarball
#   bash scripts/release.sh --version 1.0.0     # set explicit version
#   bash scripts/release.sh --npm               # also publish to npm
#   bash scripts/release.sh --target linux-x64  # cross-compile for Linux
#
# Output:
#   release/claudex-<version>-<os>-<arch>.tar.gz
#   release/install.sh  (one-line remote installer)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_DIR="$ROOT/release"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${CYAN}[release]${RESET} $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}     $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}   $*"; }
die()     { echo -e "${RED}[ERROR]${RESET}  $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}=== $* ===${RESET}\n"; }

# --------------------------------------------------------------------------- #
# Parse args
# --------------------------------------------------------------------------- #
VERSION=""
PUBLISH_NPM=false
TARGET=""  # e.g. linux-x64, darwin-arm64 (for cross-compile)
ALL_TARGETS=false
NPM_PACKAGE_NAME="${NPM_PACKAGE_NAME:-claudex-code}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v) VERSION="$2"; shift 2 ;;
    --npm)        PUBLISH_NPM=true; shift ;;
    --npm-name)   NPM_PACKAGE_NAME="$2"; shift 2 ;;
    --target)     TARGET="$2"; shift 2 ;;
    --all-targets) ALL_TARGETS=true; shift ;;
    --help|-h)
      echo "Usage: bash scripts/release.sh [--version X.Y.Z] [--npm] [--npm-name <name>] [--target <os-arch>] [--all-targets]"
      echo ""
      echo "  --version X.Y.Z    Override version (default: from package.json)"
      echo "  --npm               Publish to npm after building"
      echo "  --npm-name <name>   npm package name (default: claudex-code)"
      echo "  --target <os-arch>  Cross-compile proxy binary (e.g. linux-x64, darwin-arm64)"
      echo "  --all-targets       Build release for all 4 targets"
      echo ""
      echo "Targets for proxy binary:"
      echo "  darwin-arm64   macOS Apple Silicon (default on M-series Mac)"
      echo "  darwin-x64     macOS Intel"
      echo "  linux-x64      Linux x86-64"
      echo "  linux-arm64    Linux ARM64"
      exit 0
      ;;
    *) die "Unknown arg: $1" ;;
  esac
done

# --------------------------------------------------------------------------- #
# Detect version
# --------------------------------------------------------------------------- #
if [[ -z "$VERSION" ]]; then
  VERSION=$(python3 -c "import json; print(json.load(open('$ROOT/package.json'))['version'])" 2>/dev/null || echo "0.0.1")
fi

if $ALL_TARGETS; then
  section "Build all compatibility targets"
  for t in darwin-arm64 darwin-x64 linux-x64 linux-arm64; do
    log "Building target: $t"
    bash "$SCRIPT_DIR/release.sh" --version "$VERSION" --target "$t"
  done
  section "All targets built"
  ls -1 "$RELEASE_DIR"/claudex-"$VERSION"-*.tar.gz 2>/dev/null || true
  exit 0
fi

# Detect current platform for default target
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
[[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]] && ARCH="arm64" || ARCH="x64"
PLATFORM="${OS}-${ARCH}"
TARGET="${TARGET:-$PLATFORM}"

TARBALL_NAME="claudex-${VERSION}-${TARGET}.tar.gz"

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${BLUE}║   claudex Release Builder v${VERSION}       ║${RESET}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${RESET}"
echo ""
log "Version : $VERSION"
log "Target  : $TARGET"
log "Output  : $RELEASE_DIR/$TARBALL_NAME"
echo ""

# --------------------------------------------------------------------------- #
# Pre-flight checks
# --------------------------------------------------------------------------- #
section "Pre-flight checks"

command -v bun >/dev/null 2>&1 || die "bun not found. Install from https://bun.sh"
command -v node >/dev/null 2>&1 || die "node not found"

[[ -f "$ROOT/dist/cli.js" ]] || die "dist/cli.js not found. Run: bash scripts/setup.sh --build first"
[[ -f "$ROOT/proxy/server.ts" ]] || die "proxy/server.ts not found"
[[ -f "$ROOT/proxy/config.json" ]] || die "proxy/config.json not found"

ok "All pre-flight checks passed"

# --------------------------------------------------------------------------- #
# Prepare release directory
# --------------------------------------------------------------------------- #
section "Preparing release directory"

STAGE="$RELEASE_DIR/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# --------------------------------------------------------------------------- #
# Compile standalone proxy binary
# --------------------------------------------------------------------------- #
section "Compiling proxy → standalone binary"

log "bun build --compile proxy/server.ts → claudex-proxy"

# Map platform string to bun target
BUN_TARGET=""
case "$TARGET" in
  linux-x64)    BUN_TARGET="--target=bun-linux-x64" ;;
  linux-arm64)  BUN_TARGET="--target=bun-linux-arm64" ;;
  darwin-x64)   BUN_TARGET="--target=bun-darwin-x64" ;;
  darwin-arm64) BUN_TARGET="--target=bun-darwin-arm64" ;;
  *)            BUN_TARGET="" ;;  # native (current platform)
esac

cd "$ROOT"
# shellcheck disable=SC2086
bun build --compile $BUN_TARGET \
  --outfile "$STAGE/claudex-proxy" \
  proxy/server.ts 2>&1 | grep -v "^\s*$" || true

[[ -f "$STAGE/claudex-proxy" ]] || die "proxy binary compilation failed"
ok "claudex-proxy compiled ($(du -sh "$STAGE/claudex-proxy" | cut -f1))"

# --------------------------------------------------------------------------- #
# Copy CLI
# --------------------------------------------------------------------------- #
section "Packaging CLI"

# cli.js (patched Claude Code CLI) — requires Node.js 18+
cp "$ROOT/dist/cli.js" "$STAGE/claudex-cli.js"
ok "cli.js copied ($(du -sh "$STAGE/claudex-cli.js" | cut -f1))"

# config.json is embedded in claudex-proxy binary — no separate file needed.
# (Users can still override by placing config.json next to claudex-proxy)

# --------------------------------------------------------------------------- #
# Generate launcher (claudex = shared ~/.claude)
# --------------------------------------------------------------------------- #
section "Generating launchers"

# make_launcher <cmd_name> <home_dir> <output_file>
make_launcher() {
  local CMD="$1"
  local HOME_DIR="$2"
  local OUT="$3"

cat > "$OUT" << LAUNCHER
#!/usr/bin/env bash
# ${CMD} — Claude Code with multi-model proxy
# Subcommands: switch / model / status / restart / logs / doctor / help
# shellcheck disable=SC2016,SC2028

_CMD="${CMD}"
_DATA_DIR="${HOME_DIR}"
MYAI_INSTALL="\${MYAI_INSTALL:-\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)}"
PROXY_PORT="\${MYAI_PROXY_PORT:-4315}"
PROXY_LOG="\${TMPDIR:-/tmp}/${CMD}-proxy.log"

_cmd_rc() {
  [[ -f "\$HOME/.zshrc" ]] && echo "\$HOME/.zshrc" && return
  [[ -f "\$HOME/.bashrc" ]] && echo "\$HOME/.bashrc" && return
  echo "\$HOME/.zshrc"
}

_cmd_restart() {
  pkill -f "${CMD}-proxy\b\|claudex-proxy" 2>/dev/null || true; sleep 1
  CLAUDEX_PROVIDER="\${CLAUDEX_PROVIDER:-\${MYAI_PROVIDER:-}}" CLAUDEX_MODEL="\${CLAUDEX_MODEL:-\${MYAI_MODEL:-}}" \
  nohup "\$MYAI_INSTALL/claudex-proxy" --port "\$PROXY_PORT" > "\$PROXY_LOG" 2>&1 &
  for _i in 1 2 3 4 5 6 7 8; do sleep 1
    curl -sf "http://localhost:\${PROXY_PORT}/health" > /dev/null 2>&1 && return 0
  done
  echo "  proxy failed to start. Run: ${CMD} logs" >&2; return 1
}

_cmd_doctor() {
  echo ""
  echo "  Doctor checks"
  command -v node >/dev/null 2>&1 && echo "  node      : ok (\$(node -v))" || echo "  node      : missing"
  command -v curl >/dev/null 2>&1 && echo "  curl      : ok" || echo "  curl      : missing"
  [[ -x "\$MYAI_INSTALL/claudex-proxy" ]] && echo "  proxy bin  : ok (\$MYAI_INSTALL/claudex-proxy)" || echo "  proxy bin  : missing"
  [[ -f "\$MYAI_INSTALL/claudex-cli.js" ]] && echo "  cli file   : ok (\$MYAI_INSTALL/claudex-cli.js)" || echo "  cli file   : missing"
  echo "  provider   : \${CLAUDEX_PROVIDER:-\${MYAI_PROVIDER:-(default: openai)}}"
  echo "  model      : \${CLAUDEX_MODEL:-\${MYAI_MODEL:-(provider default)}}"
  echo "  data dir   : \${_DATA_DIR}"
  if curl -sf "http://localhost:\${PROXY_PORT}/health" > /dev/null 2>&1; then
    echo "  proxy      : running (port \$PROXY_PORT)"
  else
    echo "  proxy      : stopped"
  fi
  echo "  logs       : \$PROXY_LOG"
  echo ""
}

case "\${1:-}" in
  switch)
    _PROV="\${2:-}"
    _VALID="openai codex anthropic gemini azure bedrock"
    if [[ -z "\$_PROV" ]]; then
      echo ""
      echo "  Current provider : \${CLAUDEX_PROVIDER:-\${MYAI_PROVIDER:-(default: openai)}}"
      echo "  Current model    : \${CLAUDEX_MODEL:-\${MYAI_MODEL:-(default, see README.md)}}"
      echo ""
      echo "  Usage:  ${CMD} switch <provider>"
      echo "  Providers:"
      echo "    openai     OpenAI   (default: gpt-5.4)"
      echo "    codex      Codex / compatible API  (default: gpt-5.4)  needs CODEX_API_KEY"
      echo "    anthropic  Anthropic Claude         (default: claude-opus-4-6) needs ANTHROPIC_API_KEY"
      echo "    gemini     Google Gemini            (default: gemini-3.1-pro-preview) needs GEMINI_API_KEY"
      echo "    azure      Azure OpenAI             (default: gpt-5.4) needs AZURE_API_KEY"
      echo "    bedrock    AWS Bedrock              (default: anthropic.claude-opus-4-6) needs AWS credentials"
      echo ""
      echo "  To switch model within a provider:"
      echo "    ${CMD} model gpt-5.4-mini"
      echo ""
      exit 0
    fi
    echo "\$_VALID" | tr ' ' '\n' | grep -qx "\$_PROV" || {
      echo "  Unknown provider: \$_PROV  (valid: \$_VALID)"; exit 1; }
    _RC="\$(_cmd_rc)"
    sed -i.bak '/^export MYAI_PROVIDER=/d;/^export CLAUDEX_PROVIDER=/d' "\$_RC" 2>/dev/null && rm -f "\${_RC}.bak"
    echo "export CLAUDEX_PROVIDER=\"\$_PROV\"" >> "\$_RC"
    export CLAUDEX_PROVIDER="\$_PROV"
    echo ""
    echo "  Provider switched to: \$_PROV"
    _cmd_restart && echo "  Proxy restarted." || true
    echo "  Written to \$_RC (new terminals will also use \$_PROV)"
    echo ""
    exit 0
    ;;

  model)
    _MODEL="\${2:-}"
    _RC="\$(_cmd_rc)"
    if [[ -z "\$_MODEL" ]]; then
      echo ""
      echo "  Current model: \${CLAUDEX_MODEL:-\${MYAI_MODEL:-(using provider default)}}"
      echo ""
      echo "  Usage:  ${CMD} model <model-id>"
      echo "  Examples:"
      echo "    ${CMD} model gpt-5.4              OpenAI flagship"
      echo "    ${CMD} model gpt-5.4-mini         OpenAI faster/cheaper"
      echo "    ${CMD} model claude-opus-4-6      Anthropic flagship"
      echo "    ${CMD} model claude-sonnet-4-6    Anthropic faster"
      echo "    ${CMD} model gemini-3.1-pro-preview      Gemini flagship"
      echo "    ${CMD} model gemini-3.1-flash-lite-preview  Gemini fast"
      echo "    ${CMD} model anthropic.claude-opus-4-6   Bedrock"
      echo ""
      echo "  To reset to provider default:"
      echo "    ${CMD} model reset"
      echo ""
      exit 0
    fi
    if [[ "\$_MODEL" == "reset" ]]; then
      sed -i.bak '/^export MYAI_MODEL=/d;/^export CLAUDEX_MODEL=/d' "\$_RC" 2>/dev/null && rm -f "\${_RC}.bak"
      unset CLAUDEX_MODEL
      echo "  CLAUDEX_MODEL cleared — will use provider default."
    else
      sed -i.bak '/^export MYAI_MODEL=/d;/^export CLAUDEX_MODEL=/d' "\$_RC" 2>/dev/null && rm -f "\${_RC}.bak"
      echo "export CLAUDEX_MODEL=\"\$_MODEL\"" >> "\$_RC"
      export CLAUDEX_MODEL="\$_MODEL"
      echo ""
      echo "  Model set to: \$_MODEL"
      echo "  Written to \$_RC"
    fi
    _cmd_restart && echo "  Proxy restarted." || true
    echo ""
    exit 0
    ;;

  status)
    echo ""
    echo "  Command  : ${CMD}"
    echo "  Provider : \${CLAUDEX_PROVIDER:-\${MYAI_PROVIDER:-(default: openai)}}"
    echo "  Model    : \${CLAUDEX_MODEL:-\${MYAI_MODEL:-(provider default)}}"
    echo "  Port     : \$PROXY_PORT"
    curl -sf "http://localhost:\${PROXY_PORT}/health" > /dev/null 2>&1 \
      && echo "  Proxy    : running" || echo "  Proxy    : stopped"
    echo "  Data dir : \${_DATA_DIR}"
    echo "  Logs     : \$PROXY_LOG"
    echo ""
    exit 0
    ;;

  restart)
    echo "  Restarting proxy..."
    _cmd_restart && echo "  Proxy restarted on port \$PROXY_PORT" || true
    exit 0
    ;;

  logs)
    [[ -f "\$PROXY_LOG" ]] && tail -50 "\$PROXY_LOG" || echo "  No log found: \$PROXY_LOG"
    exit 0
    ;;

  doctor)
    _cmd_doctor
    exit 0
    ;;

  help|--help|-h)
    echo ""
    echo "  ${CMD}                        Launch Claude Code (interactive)"
    echo "  ${CMD} -p 'task'              Run non-interactively"
    echo ""
    echo "  ${CMD} switch <provider>      Switch AI provider (persistent)"
    echo "  ${CMD} switch                 Show current provider + all options"
    echo "  ${CMD} model <model-id>       Override model within current provider"
    echo "  ${CMD} model reset            Reset to provider default model"
    echo "  ${CMD} model                  Show current model + examples"
    echo "  ${CMD} status                 Proxy / config status"
    echo "  ${CMD} restart                Restart proxy"
    echo "  ${CMD} logs                   Proxy logs (debug)"
    echo "  ${CMD} doctor                 Basic diagnostics"
    echo ""
    echo "  Providers: openai | codex | anthropic | gemini | azure | bedrock"
    echo ""
    echo "  Common models:"
    echo "    openai:    gpt-5.4  gpt-5.4-mini"
    echo "    anthropic: claude-opus-4-6  claude-sonnet-4-6"
    echo "    gemini:    gemini-3.1-pro-preview  gemini-3.1-flash-lite-preview"
    echo "    bedrock:   anthropic.claude-opus-4-6"
    echo ""
    echo "  API Keys — add to ~/.zshrc then source ~/.zshrc:"
    echo "    OPENAI_API_KEY        OpenAI"
    echo "    CODEX_API_KEY         Codex  (+ CODEX_API_BASE for custom URL)"
    echo "    GEMINI_API_KEY        Gemini"
    echo "    ANTHROPIC_API_KEY     Anthropic"
    echo "    AZURE_API_KEY         Azure  (+ AZURE_OPENAI_ENDPOINT)"
    echo "    AWS_ACCESS_KEY_ID     Bedrock (+ AWS_SECRET_ACCESS_KEY, AWS_REGION)"
    echo "  Optional URL overrides:"
    echo "    OPENAI_API_BASE       OpenAI-compatible base URL"
    echo "    CODEX_API_BASE        Codex base URL"
    echo "    GEMINI_API_BASE       Gemini API base URL"
    echo "    ANTHROPIC_API_BASE    Anthropic-compatible base URL"
    echo "    AWS_BEDROCK_ENDPOINT  Bedrock endpoint override"
    echo ""
    echo "  Docs: README.md"
    echo ""
    exit 0
    ;;
esac

export CLAUDE_CONFIG_DIR="\${_DATA_DIR}"
export ANTHROPIC_BASE_URL="http://localhost:\${PROXY_PORT}"
export ANTHROPIC_API_KEY="local-proxy"

if ! curl -sf "http://localhost:\${PROXY_PORT}/health" > /dev/null 2>&1; then
  CLAUDEX_PROVIDER="\${CLAUDEX_PROVIDER:-\${MYAI_PROVIDER:-}}" CLAUDEX_MODEL="\${CLAUDEX_MODEL:-\${MYAI_MODEL:-}}" \
  nohup "\$MYAI_INSTALL/claudex-proxy" --port "\$PROXY_PORT" > "\$PROXY_LOG" 2>&1 &
  for _i in 1 2 3 4 5 6 7 8; do sleep 1
    curl -sf "http://localhost:\${PROXY_PORT}/health" > /dev/null 2>&1 && break
  done
fi

exec node "\$MYAI_INSTALL/claudex-cli.js" "\$@"
LAUNCHER

  chmod +x "$OUT"
}

# Generate launcher
make_launcher "claudex" "\$HOME/.claude" "$STAGE/claudex"
ok "launcher created: claudex (→ ~/.claude)"

# Copy docs README into stage
[[ -f "$ROOT/docs/README.md" ]] && cp "$ROOT/docs/README.md" "$STAGE/README.md"

# --------------------------------------------------------------------------- #
# Generate install.sh
# --------------------------------------------------------------------------- #
cat > "$STAGE/install.sh" << 'INSTALL'
#!/usr/bin/env bash
# install.sh — install claudex (Claude Code + multi-model proxy)
#
# Usage:
#   bash install.sh                    # default: claudex (uses ~/.claude, marketplace skills work)
#   bash install.sh --profile claudex  # explicit profile (same as default)
#
# Requirements: Node.js >= 18
set -euo pipefail

INSTALL_DIR="${MYAI_INSTALL_DIR:-$HOME/.local/bin}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="claudex"

while [[ $# -gt 0 ]]; do
  case "$1" in --profile|-p) PROFILE="$2"; shift 2 ;; *) shift ;; esac
done

[[ "$PROFILE" == "claudex" ]] || {
  echo "Unknown profile: $PROFILE (valid: claudex)"; exit 1; }

echo ""
echo "  Profile  : $PROFILE"
echo "  Install  : $INSTALL_DIR"
echo ""

mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/claudex-proxy"  "$INSTALL_DIR/claudex-proxy" && chmod +x "$INSTALL_DIR/claudex-proxy"
cp "$SCRIPT_DIR/claudex-cli.js" "$INSTALL_DIR/claudex-cli.js"
[[ -f "$SCRIPT_DIR/README.md" ]] && cp "$SCRIPT_DIR/README.md" "$INSTALL_DIR/README.md"

_init_config() {
  local DIR="${1/\$HOME/$HOME}"
  mkdir -p "$DIR"
  [[ -f "$DIR/.claude.json" ]] && return
  python3 - "$DIR" << 'PY'
import json, sys, pathlib, os
p = pathlib.Path(sys.argv[1]) / '.claude.json'
data = {'hasCompletedOnboarding': True, 'theme': 'dark',
        'customApiKeyResponses': {'approved': ['local-proxy'], 'rejected': []},
        'skipDangerousPermissionsDialogShown': True,
        'projects': {os.path.expanduser('~'): {'hasTrustDialogAccepted': True}}}
p.write_text(json.dumps(data, indent=2))
PY
}

_install_profile() {
  local CMD="$1" DATA="$2"
  cp "$SCRIPT_DIR/$CMD" "$INSTALL_DIR/$CMD" && chmod +x "$INSTALL_DIR/$CMD"
  _init_config "$DATA"
  echo "  Installed: $CMD  (data: ${DATA/\$HOME/$HOME})"
}

case "$PROFILE" in
  claudex) _install_profile claudex '$HOME/.claude' ;;
esac

# PATH
RC_FILE=""
[[ -f "$HOME/.zshrc" ]] && RC_FILE="$HOME/.zshrc"
[[ -z "$RC_FILE" && -f "$HOME/.bashrc" ]] && RC_FILE="$HOME/.bashrc"
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  [[ -n "$RC_FILE" ]] && echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$RC_FILE"
  echo ""
  echo "  Activate PATH then run:"
  echo "    source $RC_FILE"
fi

CMD="claudex"
echo ""
echo "  Run: $CMD"
echo "  Switch provider: $CMD switch openai"
echo "  Docs: $INSTALL_DIR/README.md"
echo ""
INSTALL

chmod +x "$STAGE/install.sh"
ok "install.sh created"

# --------------------------------------------------------------------------- #
# Create tarball
# --------------------------------------------------------------------------- #
section "Creating tarball"

mkdir -p "$RELEASE_DIR"
TARBALL_DIR="claudex-${VERSION}-${TARGET}"

cd "$RELEASE_DIR"
mv "$STAGE" "$TARBALL_DIR"
tar -czf "$TARBALL_NAME" "$TARBALL_DIR"
mv "$TARBALL_DIR" "$STAGE"  # restore for npm step

TARBALL_SIZE=$(du -sh "$RELEASE_DIR/$TARBALL_NAME" | cut -f1)
ok "Created: $RELEASE_DIR/$TARBALL_NAME ($TARBALL_SIZE)"

# --------------------------------------------------------------------------- #
# Optional: npm publish
# --------------------------------------------------------------------------- #
if $PUBLISH_NPM; then
  section "npm publish"

  # Build npm package structure
  NPM_DIR="$RELEASE_DIR/npm-pkg"
  rm -rf "$NPM_DIR"
  mkdir -p "$NPM_DIR/bin"

  cp "$STAGE/claudex-proxy" "$NPM_DIR/bin/"
  cp "$STAGE/claudex-cli.js" "$NPM_DIR/bin/"

  # npm launcher wrapper
  cat > "$NPM_DIR/bin/claudex" << 'NPMBIN'
#!/usr/bin/env bash
MYAI_HOME="${MYAI_HOME:-$HOME/.claude}"
PROXY_PORT="${MYAI_PROXY_PORT:-4315}"
PROXY_LOG="${TMPDIR:-/tmp}/claudex-proxy.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAUDE_CONFIG_DIR="$MYAI_HOME"
export ANTHROPIC_BASE_URL="http://localhost:${PROXY_PORT}"
export ANTHROPIC_API_KEY="local-proxy"
if ! curl -sf "http://localhost:${PROXY_PORT}/health" > /dev/null 2>&1; then
  CLAUDEX_PROVIDER="${CLAUDEX_PROVIDER:-${MYAI_PROVIDER:-}}" CLAUDEX_MODEL="${CLAUDEX_MODEL:-${MYAI_MODEL:-}}" \
  nohup "$SCRIPT_DIR/claudex-proxy" --port "$PROXY_PORT" \
    > "$PROXY_LOG" 2>&1 &
  for _i in 1 2 3 4 5 6 7 8; do sleep 1; curl -sf "http://localhost:${PROXY_PORT}/health" > /dev/null 2>&1 && break; done
fi
exec node "$SCRIPT_DIR/claudex-cli.js" "$@"
NPMBIN
  chmod +x "$NPM_DIR/bin/claudex"

  # Generate package.json for npm
  python3 - << EOF
import json

pkg = {
    "name": "${NPM_PACKAGE_NAME}",
    "version": "${VERSION}",
    "description": "Claude Code with multi-model proxy (OpenAI, Gemini, Azure, Bedrock, Codex)",
    "bin": {"claudex": "./bin/claudex"},
    "scripts": {"postinstall": "bash setup-config.sh"},
    "engines": {"node": ">=18"},
    "os": ["darwin", "linux"],
    "keywords": ["ai", "claude", "code", "llm", "openai", "gemini"],
    "license": "MIT"
}
with open("${NPM_DIR}/package.json", "w") as f:
    json.dump(pkg, f, indent=2)
print("package.json written")
EOF

  cd "$NPM_DIR"
  npm publish --access public 2>&1 || warn "npm publish failed (check npm login and package name)"
fi

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
section "Release ready"

echo -e "${BOLD}Output:${RESET}"
echo -e "  ${CYAN}$RELEASE_DIR/$TARBALL_NAME${RESET}  ($TARBALL_SIZE)"
echo ""
echo -e "${BOLD}Distribute to users:${RESET}"
echo ""
echo -e "  ${CYAN}# Option 1: tarball (recommended)${RESET}"
echo -e "  tar -xzf $TARBALL_NAME"
echo -e "  bash claudex-${VERSION}-${TARGET}/install.sh"
echo ""
echo -e "  ${CYAN}# Option 2: one-line remote install (host tarball on GitHub Releases)${RESET}"
echo -e "  curl -fsSL https://github.com/YOUR_ORG/claudex/releases/latest/download/install.sh | bash"
echo ""
echo -e "${BOLD}User requirements:${RESET}"
echo -e "  - Node.js >= 18 (https://nodejs.org/)"
echo -e "  - No bun, no npm, no build tools"
echo ""
echo -e "${BOLD}To cross-compile for other platforms:${RESET}"
echo -e "  bash scripts/release.sh --target linux-x64"
echo -e "  bash scripts/release.sh --target darwin-x64"
echo -e "  bash scripts/release.sh --target linux-arm64"
