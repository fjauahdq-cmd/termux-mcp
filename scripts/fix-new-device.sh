#!/data/data/com.termux/files/usr/bin/bash
# fix-new-device.sh v5 — instala TUDO e deixa rodando em background:
#   * binário com patch fixArgv (bug do termux-exec) + tools via root
#   * config com tools liberadas e auth.require=false (sem token obrigatório)
#   * servidor HTTP (127.0.0.1:3000) + tunnel cloudflared subindo sozinhos
#   * URL pública impressa no final
#
# Uso (uma linha só, dentro do Termux):
#   curl -fsSL https://raw.githubusercontent.com/fjauahdq-cmd/termux-mcp/main/scripts/fix-new-device.sh | bash
set -euo pipefail

log()  { printf '\033[1;32m[fix]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[fix]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fix]\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "${PREFIX:-}" ] || die "Rode dentro do Termux (\$PREFIX vazio)."

BIN_URL="https://litter.catbox.moe/kz1akl"
CFG_URL="https://raw.githubusercontent.com/fjauahdq-cmd/termux-mcp/main/config.example.yaml"
CFG_DIR="$PREFIX/var/lib/termux-mcp"
CFG="$CFG_DIR/config.yaml"
LOG_DIR="$PREFIX/var/log"
SRV_LOG="$LOG_DIR/termux-mcp-serve.log"
TUN_LOG="$LOG_DIR/termux-mcp-tunnel.log"

# --- 0. limpeza de resíduos de pastes que grudaram linhas -------------------
log "Limpando resíduos de comandos grudados..."
rm -rf "$HOME/termux-mcp/\$PREFIX" "$HOME/\$PREFIX" "$HOME/termux-mcpcp" "$PREFIX/var/lib/termux-mcpcp" 2>/dev/null || true
if [ -d "$CFG" ]; then
  warn "config.yaml era um DIRETÓRIO (paste quebrado) — removendo"
  rm -rf "$CFG"
fi

# --- 1. binário --------------------------------------------------------------
log "Baixando binário termux-mcp (android arm64, patch fixArgv + tools root)..."
curl -fsSL "$BIN_URL" -o "$PREFIX/bin/termux-mcp" || die "download falhou (link temporário expirado?) — avise no chat"
chmod +x "$PREFIX/bin/termux-mcp"
"$PREFIX/bin/termux-mcp" version || die "binário não executou"

# --- 2. config ---------------------------------------------------------------
log "Criando config.yaml (tools liberadas, auth.require=false)..."
mkdir -p "$CFG_DIR"
curl -fsSL "$CFG_URL" -o "$CFG" || die "download do config falhou"
sed -i 's/enable_sensitive: false/enable_sensitive: true/' "$CFG"
sed -i 's/enable_dangerous: false/enable_dangerous: true/' "$CFG"
sed -i 's/require: true/require: false/' "$CFG"
chmod 600 "$CFG"

# --- 3. token (gerado e salvo, mas NÃO exigido) ------------------------------
log "Gerando token (fica salvo no config, uso opcional):"
"$PREFIX/bin/termux-mcp" token new --write --config "$CFG" || true

# --- 4. reinicia servidor + tunnel em background -----------------------------
mkdir -p "$LOG_DIR"
command -v pkill >/dev/null 2>&1 || pkg install -y procps >/dev/null 2>&1 || true
log "Parando instâncias antigas (se houver)..."
pkill -f 'termux-mcp serve' 2>/dev/null || true
pkill -f 'termux-mcp tunnel' 2>/dev/null || true
sleep 1

log "Subindo servidor HTTP em background (127.0.0.1:3000)..."
nohup "$PREFIX/bin/termux-mcp" serve http --config "$CFG" </dev/null >>"$SRV_LOG" 2>&1 &
sleep 2
if grep -q 'http server listening' "$SRV_LOG" 2>/dev/null; then
  log "servidor OK"
else
  warn "servidor não confirmou escuta — veja: cat $SRV_LOG"
fi

log "Subindo tunnel cloudflared em background..."
nohup "$PREFIX/bin/termux-mcp" tunnel start --config "$CFG" </dev/null >>"$TUN_LOG" 2>&1 &

URL=""
for i in $(seq 1 15); do
  sleep 2
  URL="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$TUN_LOG" 2>/dev/null | head -1 || true)"
  [ -n "$URL" ] && break
done

# --- 5. doctor ---------------------------------------------------------------
log "Diagnóstico do ambiente:"
"$PREFIX/bin/termux-mcp" doctor --config "$CFG" || true

echo
if [ -n "$URL" ]; then
  log "======================================================"
  log "  MCP NO AR! URL pública do tunnel:"
  log "  $URL/mcp"
  log "======================================================"
  log "Atualize essa URL no cliente MCP e reconecte."
else
  warn "URL do tunnel não apareceu em 30s — veja: cat $TUN_LOG"
fi
log "Concluído! Cole TODA a saída acima no chat."
