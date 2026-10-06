#!/data/data/com.termux/files/usr/bin/bash
# fix-new-device.sh v12 — instala TUDO e deixa rodando em background:
#   * binário com patch fixArgv (bug do termux-exec) + tools via root
#   * config com tools liberadas e auth.require=false (sem token obrigatório)
#   * servidor HTTP (127.0.0.1:3000) + tunnel cloudflared subindo sozinhos
#   * kill robusto de instâncias antigas + health check de verdade
#   * tela não apaga por 10 min durante a automação
#   * binário baixado do próprio repo (sem link temporário!)
#   * URL pública impressa no final
#
# Uso (uma linha só, dentro do Termux):
#   curl -fsSL https://raw.githubusercontent.com/fjauahdq-cmd/termux-mcp/main/scripts/fix-new-device.sh | bash
set -euo pipefail

log()  { printf '\033[1;32m[fix]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[fix]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fix]\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "${PREFIX:-}" ] || die "Rode dentro do Termux (\$PREFIX vazio)."

BIN_URL="https://github.com/fjauahdq-cmd/termux-mcp/releases/latest/download/termux-mcp-android-arm64"
CFG_URL="https://raw.githubusercontent.com/fjauahdq-cmd/termux-mcp/main/config.example.yaml"
CFG_DIR="$PREFIX/var/lib/termux-mcp"
CFG="$CFG_DIR/config.yaml"
LOG_DIR="$PREFIX/var/log"
SRV_LOG="$LOG_DIR/termux-mcp-serve.log"
TUN_LOG="$LOG_DIR/termux-mcp-tunnel.log"

# --- 0. base do Termux (aparelho zerado não tem curl nem índice de pacotes) --
log "Atualizando Termux e instalando dependências básicas..."
pkg update -y || warn "pkg update falhou — continuando mesmo assim"
pkg install -y curl procps cloudflared termux-api gzip || warn "algum pacote falhou — continuando"

# --- 0.1 limpeza de resíduos de pastes que grudaram linhas ------------------
log "Limpando resíduos de comandos grudados..."
rm -rf "$HOME/termux-mcp/\$PREFIX" "$HOME/\$PREFIX" "$HOME/termux-mcpcp" "$PREFIX/var/lib/termux-mcpcp" 2>/dev/null || true
if [ -d "$CFG" ]; then
  warn "config.yaml era um DIRETÓRIO (paste quebrado) — removendo"
  rm -rf "$CFG"
fi

# --- 1. binário --------------------------------------------------------------
log "Baixando binário termux-mcp (android arm64, patch fixArgv + tools root)..."
if ! curl -fsSL "$BIN_URL" -o "$PREFIX/bin/termux-mcp" 2>/dev/null; then
  warn "release indisponível — baixando em partes do próprio repositório..."
  TMPD="$PREFIX/var/tmp"; mkdir -p "$TMPD"; B64="$TMPD/tmcp.gz.b64"; : > "$B64"
  for i in 1 2 3 4 5 6; do
    curl -fsSL "https://raw.githubusercontent.com/fjauahdq-cmd/termux-mcp/main/dist/termux-mcp.gz.b64.$i" >> "$B64" || die "falha ao baixar parte $i do binário"
  done
  base64 -d "$B64" | gunzip > "$PREFIX/bin/termux-mcp" || die "falha ao decodificar o binário"
  rm -f "$B64"
fi
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
# ATENÇÃO: o bug do termux-exec duplica o caminho no cmdline do processo
# ("termux-mcp /data/.../termux-mcp serve http ..."), então padrões como
# 'termux-mcp serve' NÃO casam. Mata qualquer processo termux-mcp:
pkill -f 'termux-mcp' 2>/dev/null || true
# espera a porta 3000 liberar de verdade (até 10s)
for i in $(seq 1 10); do
  if curl -s -o /dev/null --max-time 2 http://127.0.0.1:3000/health; then
    sleep 1
  else
    break
  fi
done

log "Subindo servidor HTTP em background (127.0.0.1:3000)..."
: > "$SRV_LOG"; : > "$TUN_LOG"
nohup "$PREFIX/bin/termux-mcp" serve http --config "$CFG" </dev/null >>"$SRV_LOG" 2>&1 &

# confirma DE VERDADE com /health (o log diz "listening" antes mesmo do bind)
OK=""
for i in $(seq 1 10); do
  sleep 1
  if curl -s -o /dev/null --max-time 2 http://127.0.0.1:3000/health; then OK=1; break; fi
done
if [ -n "$OK" ]; then
  log "servidor OK (health 200)"
else
  warn "servidor NÃO respondeu — últimas linhas do log:"
  tail -5 "$SRV_LOG" || true
fi

log "Subindo tunnel cloudflared em background..."
nohup "$PREFIX/bin/termux-mcp" tunnel start --config "$CFG" </dev/null >>"$TUN_LOG" 2>&1 &

URL=""
for i in $(seq 1 15); do
  sleep 2
  URL="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$TUN_LOG" 2>/dev/null | tail -1 || true)"
  [ -n "$URL" ] && break
done

# --- 4.5 evita a tela apagar no meio da automação (10 min) -------------------
su -c "settings put system screen_off_timeout 600000" 2>/dev/null || true

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
