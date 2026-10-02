package main

import (
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

func TestResolve(t *testing.T) {
	root := t.TempDir()

	flutter := filepath.Join(root, "flutter_app")
	write(t, filepath.Join(flutter, "pubspec.yaml"), "name: my_app # yorum\nversion: 1.0.0\n")
	write(t, filepath.Join(flutter, "lib", "main.dart"), "")

	vite := filepath.Join(root, "react-vite")
	write(t, filepath.Join(vite, "package.json"), `{"name":"vite-app","scripts":{
		"dev":"vite","build":"tsc -b && vite build","start":"vite","preview":"vite preview",
		"lint":"eslint .","test":"vitest","build:ci":"cross-env NODE_ENV=production npm run build"},
		"dependencies":{"react":"^19"}}`)

	cra := filepath.Join(root, "react-cra")
	write(t, filepath.Join(cra, "package.json"), `{"name":"cra-app","scripts":{"start":"react-scripts start","build":"react-scripts build"},"dependencies":{"react":"^18"}}`)

	next := filepath.Join(root, "next-app")
	write(t, filepath.Join(next, "package.json"), `{"name":"next-app","scripts":{"dev":"next dev --turbopack","build":"next build","start":"next start"},"dependencies":{"next":"15","react":"^19"}}`)

	mono := filepath.Join(root, "mono")
	write(t, filepath.Join(mono, "package.json"), `{"name":"mono","workspaces":["apps/*"]}`)
	write(t, filepath.Join(mono, "apps", "web", "package.json"), `{"name":"@mono/web","scripts":{"build":"vite build"}}`)

	plainVite := filepath.Join(root, "plain-vite")
	write(t, filepath.Join(plainVite, "package.json"), `{"name":"plain","scripts":{"dev":"vite"}}`)

	dotnet := filepath.Join(root, "dotnet")
	write(t, filepath.Join(dotnet, "Shop.sln"), "")
	write(t, filepath.Join(dotnet, "Api", "Api.csproj"), `<Project Sdk="Microsoft.NET.Sdk.Web"></Project>`)
	write(t, filepath.Join(dotnet, "Tool", "Tool.csproj"), `<Project Sdk="Microsoft.NET.Sdk"></Project>`)

	tests := []struct {
		name, cwd, cmd string
		want           string // "profil tech tool proje cihaz" ya da "-" (kayıt yok)
	}{
		{"F-1 flutter run", flutter, "flutter run -d ios", "flutter-run flutter flutter my_app ios"},
		{"F-1 --device-id=", flutter, "flutter run --device-id=emulator-5554", "flutter-run flutter flutter my_app emulator-5554"},
		{"F-2 fvm flutter run", flutter, "fvm flutter run -d macos", "flutter-run flutter fvm my_app macos"},
		{"F-2 fvm spawn", flutter, "fvm spawn 3.24.0 run -d chrome", "flutter-run flutter fvm my_app chrome"},
		{"F-3 flutter build apk", flutter, "flutter build apk --release", "flutter-build flutter flutter my_app apk"},
		{"F-8 alt klasör", filepath.Join(flutter, "lib"), "flutter run", "flutter-run flutter flutter my_app "},
		{"flutter pub get", flutter, "flutter pub get", "-"},

		{"R-1 npm run build", vite, "npm run build", "vite-build react npm vite-app "},
		{"R-2 pnpm build", vite, "pnpm build", "vite-build react pnpm vite-app "},
		{"R-2 yarn build", vite, "yarn build", "vite-build react yarn vite-app "},
		{"R-2 bun run build", vite, "bun run build", "vite-build react bun vite-app "},
		{"R-3 npx vite build", vite, "npx vite build", "vite-build react npx vite-app "},
		{"R-3 vite build", vite, "vite build", "vite-build react vite vite-app "},
		{"R-4 npm run dev", vite, "npm run dev", "vite-dev react npm vite-app "},
		{"R-7 start: vite", vite, "npm start", "vite-dev react npm vite-app "},
		{"R-8 workspace", mono, "npm run build -w apps/web", "vite-build vite npm @mono/web "},
		{"R-8 --workspace=", mono, "npm --workspace=apps/web run build", "vite-build vite npm @mono/web "},
		{"R-9 npm install", vite, "npm install", "-"},
		{"R-9 npm test", vite, "npm test", "-"},
		{"R-9 npm run lint", vite, "npm run lint", "-"},
		{"vite preview", vite, "npm run preview", "-"},
		{"iç içe script", vite, "npm run build:ci", "vite-build react npm vite-app "},
		{"vite (react yok)", plainVite, "npm run dev", "vite-dev vite npm plain "},
		{"vite --port 3000", plainVite, "vite --port 3000", "vite-dev vite vite plain "},

		{"R-10 CRA npm start", cra, "npm start", "cra-start react npm cra-app "},
		{"R-13 CRA build", cra, "npm run build", "cra-build react npm cra-app "},

		{"X-1 next build", next, "npm run build", "next-build next npm next-app "},
		{"X-2 next build --turbopack", next, "next build --turbopack", "next-build next next next-app "},
		{"X-3 next dev", next, "npm run dev", "next-dev next npm next-app "},
		{"X-9 next start", next, "npm run start", "-"},

		{"N-1 dotnet build", dotnet, "dotnet build", "dotnet-build dotnet dotnet Shop "},
		{"N-8 publish -c Release", dotnet, "dotnet publish -c Release Api/Api.csproj", "dotnet-build dotnet dotnet Api "},
		{"N-5 dotnet run web", filepath.Join(dotnet, "Api"), "dotnet run", "dotnet-run dotnet dotnet Api "},
		{"N-6 dotnet run console", filepath.Join(dotnet, "Tool"), "dotnet run", "dotnet-run dotnet dotnet Tool "},
		{"N-6 --project", dotnet, "dotnet run --project Tool", "dotnet-run dotnet dotnet Tool "},
		{"N-7 dotnet watch", filepath.Join(dotnet, "Api"), "dotnet watch run", "dotnet-watch dotnet dotnet Api "},
		{"N-9 dotnet test", dotnet, "dotnet test", "dotnet-test dotnet dotnet Shop "},
		{"dotnet restore", dotnet, "dotnet restore", "-"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r := resolve(strings.Fields(tc.cmd), tc.cwd)
			got := "-"
			if r != nil {
				got = strings.Join([]string{r.Profile.ID, r.Tech, r.Tool, r.Project, r.Device}, " ")
			}
			if got != tc.want {
				t.Errorf("%q → %q, beklenen %q", tc.cmd, got, tc.want)
			}
		})
	}

	if r := resolve([]string{"dotnet", "run"}, filepath.Join(dotnet, "Tool")); r == nil || !r.DotnetConsole {
		t.Error("konsol projesinde dotnet run, build bitişini hazır anı saymalı")
	}
	if r := resolve([]string{"dotnet", "run"}, filepath.Join(dotnet, "Api")); r == nil || r.DotnetConsole {
		t.Error("web projesinde dotnet run, Now listening on: satırını beklemeli")
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
