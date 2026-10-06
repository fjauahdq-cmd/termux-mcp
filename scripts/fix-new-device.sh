#!/data/data/com.termux/files/usr/bin/bash
# fix-new-device.sh v2 — instala o termux-mcp num aparelho novo.
#
# O binário é PRÉ-COMPILADO porque o Go do aparelho está quebrado pelo bug
# do termux-exec (termux-app issue 4630: programas Go recebem o próprio
# caminho como os.Args[1] extra). O binário baixado aqui já tem o patch
# fixArgv que ignora esse argumento fantasma.
#
# Uso (uma linha só, dentro do Termux):
#   curl -fsSL https://raw.githubusercontent.com/fjauahdq-cmd/termux-mcp/main/scripts/fix-new-device.sh | bash
set -euo pipefail

log()  { printf '\033[1;32m[fix]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[fix]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fix]\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "${PREFIX:-}" ] || die "Rode dentro do Termux (\$PREFIX vazio)."

BIN_URL="https://litter.catbox.moe/fqh1m0"
CFG_URL="https://raw.githubusercontent.com/fjauahdq-cmd/termux-mcp/main/config.example.yaml"
CFG_DIR="$PREFIX/var/lib/termux-mcp"
CFG="$CFG_DIR/config.yaml"

# --- 0. limpeza de resíduos de pastes que grudaram linhas -------------------
log "Limpando resíduos de comandos grudados..."
rm -rf "$HOME/termux-mcp/\$PREFIX" "$HOME/\$PREFIX" "$HOME/termux-mcpcp" "$PREFIX/var/lib/termux-mcpcp" 2>/dev/null || true
if [ -d "$CFG" ]; then
  warn "config.yaml era um DIRETÓRIO (paste quebrado) — removendo"
  rm -rf "$CFG"
fi

# --- 1. binário com patch do bug argv (termux-app#4630) ----------------------
log "Baixando binário termux-mcp (android arm64, com patch fixArgv)..."
curl -fsSL "$BIN_URL" -o "$PREFIX/bin/termux-mcp" || die "download falhou (link temporário expirado?) — avise no chat"
chmod +x "$PREFIX/bin/termux-mcp"
"$PREFIX/bin/termux-mcp" version || die "binário não executou"

# --- 2. config com tools sensíveis + perigosas -------------------------------
log "Criando config.yaml (enable_sensitive + enable_dangerous = true)..."
mkdir -p "$CFG_DIR"
curl -fsSL "$CFG_URL" -o "$CFG" || die "download do config falhou"
sed -i 's/enable_sensitive: false/enable_sensitive: true/' "$CFG"
sed -i 's/enable_dangerous: false/enable_dangerous: true/' "$CFG"
chmod 600 "$CFG"

# --- 3. token ------------------------------------------------------------------
log "Gerando token (anote se for conectar via LAN/tunnel):"
"$PREFIX/bin/termux-mcp" token new --write --config "$CFG"

# --- 4. doctor -------------------------------------------------------------------
log "Diagnóstico do ambiente:"
"$PREFIX/bin/termux-mcp" doctor --config "$CFG" || true

log "Concluído! Cole TODA a saída acima no chat."
