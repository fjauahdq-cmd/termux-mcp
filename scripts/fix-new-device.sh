#!/data/data/com.termux/files/usr/bin/bash
# fix-new-device.sh — repara a instalação do termux-mcp num aparelho novo:
# corrige o GOROOT do pacote golang, limpa resíduos de pastes que grudaram
# linhas, compila o binário do source, cria o config com as tools sensíveis
# e perigosas habilitadas, gera o token e roda o doctor.
#
# Uso (uma linha só, dentro do Termux):
#   curl -fsSL https://raw.githubusercontent.com/fjauahdq-cmd/termux-mcp/main/scripts/fix-new-device.sh | bash
set -euo pipefail

log()  { printf '\033[1;32m[fix]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[fix]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fix]\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "${PREFIX:-}" ] || die "Rode dentro do Termux ($PREFIX vazio)."
[ -d "$HOME/termux-mcp" ] || die "Checkout ~/termux-mcp não encontrado. Clone primeiro: git clone https://github.com/fjauahdq-cmd/termux-mcp ~/termux-mcp"

# --- 0. limpeza de resíduos de pastes que grudaram linhas -------------------
log "Limpando resíduos de comandos grudados..."
rm -rf "$HOME/termux-mcp/\$PREFIX" "$HOME/\$PREFIX" "$HOME/termux-mcpcp" "$PREFIX/var/lib/termux-mcpcp" 2>/dev/null || true
if [ -d "$PREFIX/var/lib/termux-mcp/config.yaml" ]; then
  warn "config.yaml existia como DIRETÓRIO (paste quebrado) — removendo"
  rm -rf "$PREFIX/var/lib/termux-mcp/config.yaml"
fi
cd "$HOME/termux-mcp"
git status --short || true

# --- 1. GOROOT (o pacote golang do Termux às vezes não exporta) --------------
export GOROOT="$PREFIX/lib/go"
export GOPATH="$HOME/go"
if ! grep -q 'export GOROOT=' "$HOME/.bashrc" 2>/dev/null; then
  printf '\nexport GOROOT=$PREFIX/lib/go\nexport GOPATH=$HOME/go\n' >> "$HOME/.bashrc"
  log "GOROOT persistido no ~/.bashrc"
fi
if ! go version; then
  warn "Go falhou mesmo com GOROOT — tentando reinstalar o pacote..."
  pkg reinstall -y golang || die "pkg reinstall golang falhou"
  go version || die "Go continua quebrado. Cole a saída no chat."
fi

# --- 2. compila do source ----------------------------------------------------
log "Compilando termux-mcp do source..."
go mod tidy
go build -o "$PREFIX/bin/termux-mcp" ./cmd/termux-mcp
"$PREFIX/bin/termux-mcp" version || die "binário novo não responde ao 'version'"

# --- 3. config com tools sensíveis + perigosas -------------------------------
log "Criando config.yaml (enable_sensitive + enable_dangerous = true)..."
mkdir -p "$PREFIX/var/lib/termux-mcp"
cp config.example.yaml "$PREFIX/var/lib/termux-mcp/config.yaml"
sed -i 's/enable_sensitive: false/enable_sensitive: true/' "$PREFIX/var/lib/termux-mcp/config.yaml"
sed -i 's/enable_dangerous: false/enable_dangerous: true/' "$PREFIX/var/lib/termux-mcp/config.yaml"
chmod 600 "$PREFIX/var/lib/termux-mcp/config.yaml"

# --- 4. token ------------------------------------------------------------------
log "Gerando token (anote se for conectar via LAN/tunnel):"
"$PREFIX/bin/termux-mcp" token new --write --config "$PREFIX/var/lib/termux-mcp/config.yaml"

# --- 5. doctor ------------------------------------------------------------------
log "Diagnóstico do ambiente:"
"$PREFIX/bin/termux-mcp" doctor --config "$PREFIX/var/lib/termux-mcp/config.yaml" || true

log "Concluído! Cole TODA a saída acima no chat."
