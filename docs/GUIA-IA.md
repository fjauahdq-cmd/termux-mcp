# Guia de uso para agentes de IA (termux-mcp, fork fjauahdq-cmd)

Este fork roda 100% no aparelho (Android + Termux + root) e expõe 58 tools MCP.
Este guia existe para a IA usar as tools **certinho** — ele foi escrito a partir
de erros reais cometidos em campo. Leia antes de operar.

## Regra nº 1 (a mais importante — queimei etapas por ignorar isso)

**NUNCA meça coordenadas de botão em thumbnail.** Thumbnails (max_width 360-480)
servem SÓ para checagem rápida de estado ("mudou de tela?"). Para ler texto e
calcular onde tocar:

1. `take_screenshot` com `max_width: 1280`, `quality: 70`
2. Leia o botão, meça o centro na imagem
3. Converta: `x_disp = x_img * (largura_disp / largura_img)` (o meta da
   screenshot informa os dois tamanhos, ex.: `1280x720 → 480x270`)
4. Toque 1x, no centro do alvo. Se a imagem já está em 1280 num display 1280,
   a coordenada é direta (fator 1).

Erros que isso evita: tocar fora da tela, tocar em pasta errada no launcher,
errar botão por 50-100px.

## Regra nº 2 — tela estática ≠ app travado

Screenshots byte-idênticas NÃO significam crash. Jogos em diálogo/modal ficam
com o frame estático por minutos esperando input. Antes de concluir "travou":

- tire screenshot em 1280 e LEIA o que está na tela — provavelmente há um
  diálogo esperando aceite;
- só suspeite de travamento se não houver diálogo nenhum e nem animação por
  vários minutos.

## Regra nº 3 — confirme o efeito do toque na mesma chamada

Use `action_batch` com `[{tap}, {wait ~1500ms}, {screenshot max_width 480}]`.
Você toca e já vê o resultado numa chamada só. Se nada mudou, NÃO repita o
mesmo toque às cegas: re-leia a tela em 1280 e recalcule.

## Diálogos e casos especiais

- **Permissão do Android** ("Permitir que app X acesse...") → são janelas
  nativas: `dump_ui` mostra os `bounds` exatos dos botões; toque no centro.
- **Consentimento WebView** ("app quer usar site Y para login") → conteúdo web,
  não aparece no dump_ui e os toques podem falhar. Evite o fluxo: use
  `input_keyevent 4` (voltar) e escolha o caminho sem WebView (ex.: Guest em
  vez de login Google/Activision).
- **Lock screen (EMUI)** → swipe quase nunca destrava; use
  `su -c "wm dismiss-keyguard"` via `execute_command` wait=true.
- **Barra de notificações aberta atrapalha toques** → feche com keyevent 4.

## Tools e quando usar

| Tool | Uso |
|---|---|
| `take_screenshot` | 1280/q70 para ler e medir; 360-480 para checagem rápida; jpeg |
| `action_batch` | Sequências tap/swipe/text/key/wait/screenshot/dump em 1 chamada |
| `dump_ui` | Hierarquia XML de views nativas (diálogos de sistema) |
| `execute_command` | `wait:true` = stdout/stderr/exit_code imediato; `wait:false` = background |
| `tap_screen` / `swipe_screen` | Toque/gesto via root, síncrono |
| `input_keyevent` | 3=home, 4=voltar, 187=recentes, KEYCODE_WAKEUP=acordar |
| `input_text` | Digita no campo focado |

## Notas do ambiente (Android virtual, LXC, Android 10)

- Display 1280x720 landscape / 720x1280 portrait; janela de app pode ser
  1184x720 (barra lateral) — meça sempre pela screenshot real.
- Bug do termux-exec: injeta o caminho do binário como os.Args[1]. O binário
  deste fork já tem patch (fixArgv). Outros binários Go compilados para este
  ambiente podem precisar do mesmo workaround; e o toolchain Go local quebra
  por isso (compile fora do aparelho / GitHub Actions).
- Compilar com Go 1.25 (Go 1.27 vanilla causa segfault no Android 10).
- `input`, `screencap`, `uiautomator` ficam fora do PATH do servidor; as tools
  usam caminho absoluto via root, então o "missing" do doctor é esperado.
