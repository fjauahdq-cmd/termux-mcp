// Package ui implements Module F: UI automation (dangerous tier, opt-in).
//
// All device commands run as root via `su -c` with absolute /system/bin
// paths, so they work without android-tools or wireless debugging and do
// not depend on PATH. Screenshots are returned inline as image content,
// with optional downscaling to keep payloads small.
package ui

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"math"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	"termux-mcp/internal/exec"
	"termux-mcp/internal/registry"
	"termux-mcp/internal/tools/files"
	"termux-mcp/internal/tools/kit"
)

const (
	sysInput       = "/system/bin/input"
	sysScreencap   = "/system/bin/screencap"
	sysUiautomator = "/system/bin/uiautomator"
	tmpShot        = "/sdcard/.termux-mcp-shot.png"
	tmpDump        = "/sdcard/.termux-mcp-dump.xml"
)

// All returns the UI automation module's tools.
func All(k *kit.Kit) []registry.Tool {
	return []registry.Tool{
		{Def: mcp.NewTool("take_screenshot",
			mcp.WithDescription("Capture the screen and return it inline as an image (root; no android-tools needed). Use max_width (e.g. 360) to keep the payload small and fast."),
			mcp.WithString("output", mcp.Description("Optional: also save the final image to this path (inside an allowed root)")),
			mcp.WithString("format", mcp.Description("jpeg (default) or png"), mcp.Enum("jpeg", "png")),
			mcp.WithNumber("quality", mcp.Description("JPEG quality 1-100 (default 60)"), mcp.Min(1), mcp.Max(100)),
			mcp.WithNumber("max_width", mcp.Description("If >0, downscale to this width in pixels, keeping aspect ratio"), mcp.Min(0))),
			Handler: takeScreenshot(k),
			Meta:    registry.Meta{Module: "ui", Tier: registry.TierDangerous}},

		{Def: mcp.NewTool("dump_ui",
			mcp.WithDescription("Dump the current UI hierarchy XML via uiautomator (root) and return it inline.")),
			Handler: dumpUI(k),
			Meta:    registry.Meta{Module: "ui", Tier: registry.TierDangerous}},

		{Def: mcp.NewTool("tap_screen",
			mcp.WithDescription("Tap at screen coordinates (root, synchronous)."),
			mcp.WithNumber("x", mcp.Required(), mcp.Description("X in pixels"), mcp.Min(0)),
			mcp.WithNumber("y", mcp.Required(), mcp.Description("Y in pixels"), mcp.Min(0))),
			Handler: tapScreen(k),
			Meta:    registry.Meta{Module: "ui", Tier: registry.TierDangerous}},

		{Def: mcp.NewTool("swipe_screen",
			mcp.WithDescription("Swipe from one point to another (root, synchronous)."),
			mcp.WithNumber("x1", mcp.Required(), mcp.Description("Start X"), mcp.Min(0)),
			mcp.WithNumber("y1", mcp.Required(), mcp.Description("Start Y"), mcp.Min(0)),
			mcp.WithNumber("x2", mcp.Required(), mcp.Description("End X"), mcp.Min(0)),
			mcp.WithNumber("y2", mcp.Required(), mcp.Description("End Y"), mcp.Min(0)),
			mcp.WithNumber("duration", mcp.Description("Duration in ms (default 300)"), mcp.Min(0))),
			Handler: swipeScreen(k),
			Meta:    registry.Meta{Module: "ui", Tier: registry.TierDangerous}},

		{Def: mcp.NewTool("input_text",
			mcp.WithDescription("Type text into the focused field (root)."),
			mcp.WithString("text", mcp.Required(), mcp.Description("Text to type"))),
			Handler: inputText(k),
			Meta:    registry.Meta{Module: "ui", Tier: registry.TierDangerous}},

		{Def: mcp.NewTool("input_keyevent",
			mcp.WithDescription("Send a key event (root)."),
			mcp.WithString("keycode", mcp.Required(), mcp.Description("Keycode number or name, e.g. 4, KEYCODE_BACK, KEYCODE_ENTER"))),
			Handler: inputKeyevent(k),
			Meta:    registry.Meta{Module: "ui", Tier: registry.TierDangerous}},

		{Def: mcp.NewTool("go_home",
			mcp.WithDescription("Press the Home key (keyevent 3, root).")),
			Handler: keyevent(k, "3"),
			Meta:    registry.Meta{Module: "ui", Tier: registry.TierDangerous}},

		{Def: mcp.NewTool("go_back",
			mcp.WithDescription("Press the Back key (keyevent 4, root).")),
			Handler: keyevent(k, "4"),
			Meta:    registry.Meta{Module: "ui", Tier: registry.TierDangerous}},

		{Def: mcp.NewTool("open_recent_apps",
			mcp.WithDescription("Open the recent-apps switcher (keyevent 187, root).")),
			Handler: keyevent(k, "187"),
			Meta:    registry.Meta{Module: "ui", Tier: registry.TierDangerous}},

		{Def: mcp.NewTool("action_batch",
			mcp.WithDescription("Run a sequence of UI actions in ONE call. Actions: tap {x,y}, swipe {x1,y1,x2,y2,duration?}, text {text}, key {code}, wait {ms}, screenshot {format?,quality?,max_width?}, dump {}. Example: [{\"type\":\"tap\",\"x\":540,\"y\":1200},{\"type\":\"wait\",\"ms\":800},{\"type\":\"screenshot\",\"max_width\":360}]"),
			mcp.WithArray("actions", mcp.Required(), mcp.Description("List of action objects, executed in order"), mcp.Items(map[string]any{"type": "object"})),
			mcp.WithBoolean("continue_on_error", mcp.Description("Keep running after a failed action (default false)"))),
			Handler: actionBatch(k),
			Meta:    registry.Meta{Module: "ui", Tier: registry.TierDangerous}},
	}
}

// shq single-quotes a string for safe embedding in `su -c '...'` shells.
func shq(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

var (
	suPath string
	suOnce sync.Once
)

// findSu locates a working su binary. /system/bin is often not on the
// server's PATH (doctor reports input/screencap as "missing" for the same
// reason), so probe the usual absolute locations too.
func findSu() string {
	suOnce.Do(func() {
		for _, c := range []string{"su", "/system/bin/su", "/system/xbin/su", "/sbin/su", "/su/bin/su", "/data/adb/magisk/su"} {
			if strings.Contains(c, "/") {
				if fi, err := os.Stat(c); err == nil && !fi.IsDir() {
					suPath = c
					return
				}
			} else if p, err := exec.LookPath(c); err == nil {
				suPath = p
				return
			}
		}
		suPath = "su"
	})
	return suPath
}

// rootShell runs a shell command line as root.
func rootShell(k *kit.Kit, ctx context.Context, shellCmd string) (*exec.Result, error) {
	return k.Run(ctx, findSu(), []string{"-c", shellCmd}, 0)
}

// inputDo runs `/system/bin/input ...` as root.
func inputDo(k *kit.Kit, ctx context.Context, args ...string) error {
	quoted := make([]string, len(args))
	for i, a := range args {
		quoted[i] = shq(a)
	}
	res, err := rootShell(k, ctx, sysInput+" "+strings.Join(quoted, " "))
	if err != nil {
		return fmt.Errorf("su: %v (root disponível? teste: su -c id)", err)
	}
	if res.ExitCode != 0 {
		return fmt.Errorf("input exited %d: %s", res.ExitCode, strings.TrimSpace(res.Stderr))
	}
	return nil
}

func inputRun(k *kit.Kit, ctx context.Context, args ...string) (*mcp.CallToolResult, error) {
	if err := inputDo(k, ctx, args...); err != nil {
		return kit.ResultError("%v", err), nil
	}
	return kit.ResultText("ok"), nil
}

// dumpCore returns the current UI hierarchy XML.
func dumpCore(k *kit.Kit, ctx context.Context) (string, error) {
	cmd := fmt.Sprintf("%s dump %s >/dev/null 2>&1 && cat %s ; rm -f %s",
		sysUiautomator, tmpDump, tmpDump, tmpDump)
	res, err := rootShell(k, ctx, cmd)
	if err != nil {
		return "", fmt.Errorf("su: %v (root disponível? teste: su -c id)", err)
	}
	if res.ExitCode != 0 {
		return "", fmt.Errorf("uiautomator exited %d: %s", res.ExitCode, strings.TrimSpace(res.Stderr))
	}
	out := strings.TrimSpace(res.Stdout)
	if !strings.HasPrefix(out, "<") {
		return "", fmt.Errorf("dump vazio ou inválido: %s", out)
	}
	return res.Stdout, nil
}

func dumpUI(k *kit.Kit) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		out, err := dumpCore(k, ctx)
		if err != nil {
			return kit.ResultError("%v", err), nil
		}
		return kit.ResultText("%s", out), nil
	}
}

// scaleNearest downscales src to width newW using nearest neighbor
// (stdlib-only; thumbnails don't need fancy filters).
func scaleNearest(src image.Image, newW int) image.Image {
	sb := src.Bounds()
	sw, sh := sb.Dx(), sb.Dy()
	if newW <= 0 || newW >= sw {
		return src
	}
	nh := int(math.Round(float64(sh) * float64(newW) / float64(sw)))
	if nh < 1 {
		nh = 1
	}
	dst := image.NewRGBA(image.Rect(0, 0, newW, nh))
	for y := 0; y < nh; y++ {
		sy := sb.Min.Y + y*sh/nh
		for x := 0; x < newW; x++ {
			dst.Set(x, y, src.At(sb.Min.X+x*sw/newW, sy))
		}
	}
	return dst
}

// shotCore captures the screen, optionally downscales/re-encodes it, saves a
// copy in kit.ShotsDir (served at /shots/ over HTTP) and returns the final
// bytes plus a short human-readable meta line.
func shotCore(k *kit.Kit, ctx context.Context, format string, quality, maxW int) (data []byte, mime, meta, ext string, err error) {
	if format == "" {
		format = "jpeg"
	}
	if format != "jpeg" && format != "png" {
		return nil, "", "", "", fmt.Errorf("format deve ser jpeg ou png")
	}
	if quality <= 0 || quality > 100 {
		quality = 60
	}

	res, err := rootShell(k, ctx, fmt.Sprintf("%s -p %s && chmod 666 %s", sysScreencap, tmpShot, tmpShot))
	if err != nil {
		return nil, "", "", "", fmt.Errorf("su: %v (root disponível? teste: su -c id)", err)
	}
	if res.ExitCode != 0 {
		return nil, "", "", "", fmt.Errorf("screencap exited %d: %s", res.ExitCode, strings.TrimSpace(res.Stderr))
	}
	raw, rerr := os.ReadFile(tmpShot)
	_, _ = rootShell(k, ctx, "rm -f "+tmpShot) // best-effort cleanup (arquivo é do root)
	if rerr != nil {
		return nil, "", "", "", fmt.Errorf("read screenshot: %v", rerr)
	}

	src, err := png.Decode(strings.NewReader(string(raw)))
	if err != nil {
		return nil, "", "", "", fmt.Errorf("decode png: %v", err)
	}
	sw, sh := src.Bounds().Dx(), src.Bounds().Dy()
	img := scaleNearest(src, maxW)
	dw, dh := img.Bounds().Dx(), img.Bounds().Dy()

	var buf bytes.Buffer
	if format == "jpeg" {
		mime = "image/jpeg"
		err = jpeg.Encode(&buf, img, &jpeg.Options{Quality: quality})
	} else {
		mime = "image/png"
		err = png.Encode(&buf, img)
	}
	if err != nil {
		return nil, "", "", "", fmt.Errorf("encode %s: %v", format, err)
	}
	data = buf.Bytes()
	meta = fmt.Sprintf("screenshot %dx%d → %dx%d %s q%d (%.1f KB)", sw, sh, dw, dh, format, quality, float64(len(data))/1024)

	ext = "jpg"
	if format == "png" {
		ext = "png"
	}
	_ = os.MkdirAll(kit.ShotsDir, 0o755)
	if werr := os.WriteFile(kit.ShotsDir+"/latest."+ext, data, 0o644); werr != nil {
		meta += " | falha ao salvar em " + kit.ShotsDir
	}
	return data, mime, meta, ext, nil
}

func takeScreenshot(k *kit.Kit) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		data, mime, meta, ext, err := shotCore(k, ctx,
			kit.StrArg(req, "format"),
			int(math.Round(kit.NumArg(req, "quality"))),
			int(math.Round(kit.NumArg(req, "max_width"))),
		)
		if err != nil {
			return kit.ResultError("%v", err), nil
		}
		if host := kit.PublicHost(ctx); host != "" {
			meta += " | url: https://" + host + "/shots/latest." + ext
		}
		if out := kit.StrArg(req, "output"); out != "" {
			if p, rerr := files.Resolve(out, files.Roots(&k.Cfg.Tools)); rerr == nil {
				if werr := os.WriteFile(p, data, 0o644); werr == nil {
					meta += " | salvo em " + p
				}
			}
		}
		return &mcp.CallToolResult{Content: []mcp.Content{
			mcp.NewImageContent(base64.StdEncoding.EncodeToString(data), mime),
			mcp.NewTextContent(meta),
		}}, nil
	}
}

func tapScreen(k *kit.Kit) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		x := int(math.Round(kit.NumArg(req, "x")))
		y := int(math.Round(kit.NumArg(req, "y")))
		return inputRun(k, ctx, "tap", itoa(x), itoa(y))
	}
}

func swipeScreen(k *kit.Kit) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		args := []string{"swipe",
			itoa(int(math.Round(kit.NumArg(req, "x1")))),
			itoa(int(math.Round(kit.NumArg(req, "y1")))),
			itoa(int(math.Round(kit.NumArg(req, "x2")))),
			itoa(int(math.Round(kit.NumArg(req, "y2")))),
		}
		if d := int(math.Round(kit.NumArg(req, "duration"))); d > 0 {
			args = append(args, itoa(d))
		}
		return inputRun(k, ctx, args...)
	}
}

func inputText(k *kit.Kit) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		text, err := kit.RequireStr(req, "text")
		if err != nil {
			return kit.ResultError("%v", err), nil
		}
		return inputRun(k, ctx, "text", text)
	}
}

func inputKeyevent(k *kit.Kit) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		code, err := kit.RequireStr(req, "keycode")
		if err != nil {
			return kit.ResultError("%v", err), nil
		}
		return inputRun(k, ctx, "keyevent", code)
	}
}

func keyevent(k *kit.Kit, code string) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return inputRun(k, ctx, "keyevent", code)
	}
}

// actionBatch executes a sequence of UI actions in a single MCP call.
func actionBatch(k *kit.Kit) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		raw, _ := kit.Args(req)["actions"].([]any)
		if len(raw) == 0 {
			return kit.ResultError("actions vazio ou inválido"), nil
		}
		cont := kit.BoolArg(req, "continue_on_error")
		var out []mcp.Content
		failed := false
		addf := func(format string, a ...any) { out = append(out, mcp.NewTextContent(fmt.Sprintf(format, a...))) }

		for i, a := range raw {
			m, _ := a.(map[string]any)
			typ, _ := m["type"].(string)
			num := func(key string) float64 { n, _ := m[key].(float64); return n }
			str := func(key string) string { s, _ := m[key].(string); return s }

			var err error
			switch typ {
			case "tap":
				err = inputDo(k, ctx, "tap", itoa(int(num("x"))), itoa(int(num("y"))))
			case "swipe":
				args := []string{"swipe", itoa(int(num("x1"))), itoa(int(num("y1"))), itoa(int(num("x2"))), itoa(int(num("y2")))}
				if d := int(num("duration")); d > 0 {
					args = append(args, itoa(d))
				}
				err = inputDo(k, ctx, args...)
			case "text":
				err = inputDo(k, ctx, "text", str("text"))
			case "key":
				err = inputDo(k, ctx, "keyevent", str("code"))
			case "wait":
				ms := int(num("ms"))
				if ms <= 0 {
					ms = 500
				}
				select {
				case <-ctx.Done():
					err = ctx.Err()
				case <-time.After(time.Duration(ms) * time.Millisecond):
				}
			case "screenshot":
				var data []byte
				var mime, meta, ext string
				data, mime, meta, ext, err = shotCore(k, ctx, str("format"), int(num("quality")), int(num("max_width")))
				if err == nil {
					if host := kit.PublicHost(ctx); host != "" {
						meta += " | url: https://" + host + "/shots/latest." + ext
					}
					out = append(out,
						mcp.NewImageContent(base64.StdEncoding.EncodeToString(data), mime),
						mcp.NewTextContent(fmt.Sprintf("ação %d: %s", i, meta)))
				}
			case "dump":
				var xml string
				xml, err = dumpCore(k, ctx)
				if err == nil {
					addf("ação %d dump:\n%s", i, xml)
				}
			default:
				err = fmt.Errorf("tipo desconhecido %q", typ)
			}

			if err != nil {
				failed = true
				addf("ação %d (%s): ERRO: %v", i, typ, err)
				if !cont {
					break
				}
			} else if typ != "screenshot" && typ != "dump" {
				addf("ação %d (%s): ok", i, typ)
			}
		}

		return &mcp.CallToolResult{Content: out, IsError: failed && !cont}, nil
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
