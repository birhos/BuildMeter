package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// write, test klasöründe dosya oluşturur.
func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestResolve, spec/resolve-cases.json içindeki vakaları doğrular. Editör eklentisi
// (vscode-extension/test/resolve.test.js) aynı dosyayı kullanır.
func TestResolve(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "spec", "resolve-cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var spec struct {
		Files map[string]string `json:"files"`
		Cases []struct {
			Name, Cwd, Cmd, Want string
			DotnetConsole        *bool `json:"dotnetConsole"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &spec); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	for name, content := range spec.Files {
		write(t, filepath.Join(root, filepath.FromSlash(name)), content)
	}
	for _, tc := range spec.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			r := resolve(strings.Fields(tc.Cmd), filepath.Join(root, filepath.FromSlash(tc.Cwd)))
			got := "-"
			if r != nil {
				got = strings.Join([]string{r.Profile.ID, r.Tech, r.Tool, r.Project, r.Device}, " ")
			}
			if got != tc.Want {
				t.Errorf("%q → %q, beklenen %q", tc.Cmd, got, tc.Want)
			}
			if tc.DotnetConsole != nil && (r == nil || r.DotnetConsole != *tc.DotnetConsole) {
				t.Errorf("%q: DotnetConsole beklenen %v", tc.Cmd, *tc.DotnetConsole)
			}
		})
	}
}

func TestReadySignals(t *testing.T) {
	byID := map[string]*Profile{}
	for _, p := range profiles {
		byID[p.ID] = p
	}
	tests := []struct {
		profile, line string
		want          bool
	}{
		{"flutter-run", "Flutter run key commands.", true},
		{"flutter-run", "A Dart VM Service on iPhone 16 is available at: http://127.0.0.1:5555/", true},
		{"flutter-run", "Launching lib/main.dart on iPhone 16 in debug mode...", false},
		{"next-dev", " ✓ Ready in 1234ms", true},
		{"next-dev", "   ▲ Next.js 15.0.0", false},
		{"next-dev", "ready - started server on 0.0.0.0:3000, url: http://localhost:3000", true},
		{"vite-dev", "  VITE v6.0.0  ready in 312 ms", true},
		{"vite-dev", "  ➜  Local:   http://localhost:5173/", false},
		{"cra-start", "Compiled successfully!", true},
		{"cra-start", "Compiled with warnings.", true},
		{"cra-start", "webpack compiled successfully", true},
		{"dotnet-run", "      Now listening on: http://localhost:5000", true},
		{"dotnet-run", "info: Microsoft.Hosting.Lifetime[0]", false},
		{"dotnet-watch", "dotnet watch 🚀 Started", true},
		{"dotnet-watch", "dotnet watch 🔥 Hot reload enabled.", false},
	}
	for _, tc := range tests {
		if got := byID[tc.profile].IsReady(tc.line); got != tc.want {
			t.Errorf("%s %q → %v, beklenen %v", tc.profile, tc.line, got, tc.want)
		}
	}
}

func TestLineScannerStripsColorsAndSplitsChunks(t *testing.T) {
	var seen []string
	s := newLineScanner(func(line string) bool {
		seen = append(seen, line)
		return strings.Contains(line, "Ready in")
	})
	_, _ = s.Write([]byte("\x1b[32m ✓\x1b[39m Rea"))
	_, _ = s.Write([]byte("dy in 900ms\r\nsonraki satır\n"))
	last := seen[len(seen)-1]
	if last != " ✓ Ready in 900ms" {
		t.Fatalf("son görülen satır %q", last)
	}
	for _, l := range seen {
		if l == "sonraki satır" {
			t.Fatal("eşleşmeden sonra tarama durmalı")
		}
	}
}

func TestStatusFor(t *testing.T) {
	cases := map[int]string{0: "success", 1: "failed", 130: "cancelled", 143: "cancelled", 0xC000013A: "cancelled"}
	for rc, want := range cases {
		if got := statusFor(rc, "success"); got != want {
			t.Errorf("statusFor(%d) = %s, beklenen %s", rc, got, want)
		}
	}
	if statusFor(0, "cancelled") != "cancelled" {
		t.Error("hazır sinyali gelmeden 0 ile biten run iptal sayılmalı")
	}
}

// TestOutputFixtures, araçların gerçek çıktılarında (spec/fixtures/output/<profil>/) hazır
// sinyalinin yakalandığını doğrular. Yeni bir araç sürümünün çıktısı eklendiğinde test
// sinyalin hâlâ eşleşip eşleşmediğini gösterir.
func TestOutputFixtures(t *testing.T) {
	root := filepath.Join("..", "spec", "fixtures", "output")
	dirs, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	byID := map[string]*Profile{}
	for _, p := range profiles {
		byID[p.ID] = p
	}
	for _, dir := range dirs {
		p := byID[dir.Name()]
		if p == nil {
			t.Errorf("%s: böyle bir profil yok", dir.Name())
			continue
		}
		files, _ := os.ReadDir(filepath.Join(root, dir.Name()))
		for _, f := range files {
			data, err := os.ReadFile(filepath.Join(root, dir.Name(), f.Name()))
			if err != nil {
				t.Fatal(err)
			}
			ready := false
			s := newLineScanner(func(line string) bool { ready = p.IsReady(line); return ready })
			// Gerçek akıştaki gibi küçük parçalar halinde ver.
			for i := 0; i < len(data); i += 7 {
				_, _ = s.Write(data[i:min(i+7, len(data))])
			}
			if !ready {
				t.Errorf("%s/%s: hazır sinyali bulunamadı", dir.Name(), f.Name())
			}
		}
	}
}
