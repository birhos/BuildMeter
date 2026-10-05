package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Resolved, sarılan bir komutun hangi profil ile ve hangi alanlarla kaydedileceğidir.
type Resolved struct {
	Profile *Profile
	Tech    string
	Tool    string // flutter, fvm, dotnet, npm, pnpm, yarn, bun, npx, next, vite …
	Project string
	Device  string
	// dotnet run: proje web ya da worker uygulaması değilse hazır anı build'in bitişidir.
	DotnetConsole bool
}

// resolve, komut satırını profile çözer. Hiçbir profile uymayan komutlar için nil döner.
func resolve(argv []string, cwd string) *Resolved {
	if len(argv) == 0 {
		return nil
	}
	name := commandName(argv[0])
	args := argv[1:]

	switch name {
	case "flutter":
		return resolveFlutter("flutter", args, cwd)
	case "fvm":
		switch firstPositional(args) {
		case "flutter":
			return resolveFlutter("fvm", afterPositional(args, 1), cwd)
		case "spawn": // fvm spawn <sürüm> run …
			return resolveFlutter("fvm", afterPositional(args, 2), cwd)
		}
		return nil
	case "dotnet":
		return resolveDotnet(args, cwd)
	case "npm", "pnpm", "yarn", "bun":
		return resolvePackageManager(name, args, cwd)
	case "npx", "bunx":
		return resolveJSTool(name, stripRunnerFlags(args), cwd)
	case "next", "vite", "react-scripts":
		return resolveJSTool(name, argv, cwd)
	}
	return nil
}

// commandName: "/usr/bin/npm" → "npm", "npm.cmd" → "npm".
func commandName(path string) string {
	base := strings.ToLower(filepath.Base(strings.ReplaceAll(path, `\`, "/")))
	for _, ext := range []string{".exe", ".cmd", ".bat", ".ps1"} {
		base = strings.TrimSuffix(base, ext)
	}
	return base
}

// afterPositional, n'inci konumsal argümandan sonrasını döndürür.
func afterPositional(args []string, n int) []string {
	seen := 0
	for i, a := range args {
		if !strings.HasPrefix(a, "-") {
			seen++
			if seen == n {
				return args[i+1:]
			}
		}
	}
	return nil
}

// MARK: - Flutter

func resolveFlutter(tool string, args []string, cwd string) *Resolved {
	p := matchProfile("flutter", args)
	if p == nil {
		return nil
	}
	r := &Resolved{Profile: p, Tech: p.Tech, Tool: tool, Project: flutterProject(cwd)}
	if p.Kind == "build" {
		// flutter build apk → cihaz alanı "apk"
		r.Device = firstPositional(afterPositional(args, 1))
	} else {
		r.Device = flagValue(args, "-d", "--device-id")
	}
	return r
}

var pubspecName = regexp.MustCompile(`(?m)^name:\s*([^\s#]+)`)

func flutterProject(cwd string) string {
	if dir, ok := findUp(cwd, "pubspec.yaml"); ok {
		if data, err := os.ReadFile(filepath.Join(dir, "pubspec.yaml")); err == nil {
			if m := pubspecName.FindSubmatch(data); m != nil {
				return string(m[1])
			}
		}
		return filepath.Base(dir)
	}
	return filepath.Base(cwd)
}

// MARK: - .NET

func resolveDotnet(args []string, cwd string) *Resolved {
	p := matchProfile("dotnet", args)
	if p == nil {
		return nil
	}
	rest := afterPositional(args, 1)
	if p.ID == "dotnet-watch" && firstPositional(rest) == "run" {
		rest = afterPositional(rest, 1)
	}
	target := flagValue(rest, "--project")
	if target == "" && p.ID != "dotnet-run" && p.ID != "dotnet-watch" {
		target = dotnetTargetArg(rest, cwd)
	}
	file := dotnetProjectFile(cwd, target)
	r := &Resolved{Profile: p, Tech: p.Tech, Tool: "dotnet", Project: filepath.Base(cwd)}
	if file != "" {
		r.Project = strings.TrimSuffix(filepath.Base(file), filepath.Ext(file))
	}
	if p.ID == "dotnet-run" {
		r.DotnetConsole = !isDotnetHostedApp(file)
	}
	return r
}

// dotnetTargetArg, "dotnet build -c Release Api/Api.csproj" gibi çağrılarda proje argümanını
// bulur: proje/çözüm uzantılı ya da var olan bir klasörü gösteren konumsal argüman.
func dotnetTargetArg(args []string, cwd string) string {
	for _, a := range args {
		if strings.HasPrefix(a, "-") {
			continue
		}
		lower := strings.ToLower(a)
		for _, ext := range []string{".sln", ".slnx", ".csproj", ".fsproj", ".vbproj"} {
			if strings.HasSuffix(lower, ext) {
				return a
			}
		}
		path := a
		if !filepath.IsAbs(path) {
			path = filepath.Join(cwd, path)
		}
		if info, err := os.Stat(path); err == nil && info.IsDir() {
			return a
		}
	}
	return ""
}

// dotnetProjectFile, dotnet'in kullanacağı proje ya da çözüm dosyasını bulur:
// verilen dosya, verilen klasördeki ya da çalışma klasöründeki tek .sln/.csproj.
func dotnetProjectFile(cwd, target string) string {
	dir := cwd
	if target != "" {
		if !filepath.IsAbs(target) {
			target = filepath.Join(cwd, target)
		}
		if info, err := os.Stat(target); err == nil && !info.IsDir() {
			return target
		}
		dir = target
	}
	for _, pattern := range []string{"*.sln", "*.slnx", "*.csproj", "*.fsproj", "*.vbproj"} {
		if matches, _ := filepath.Glob(filepath.Join(dir, pattern)); len(matches) == 1 {
			return matches[0]
		}
	}
	return ""
}

// isDotnetHostedApp: web, worker ve Blazor projeleri "hazır" satırı basar; konsol uygulamaları basmaz.
func isDotnetHostedApp(file string) bool {
	if file == "" || !strings.HasSuffix(strings.ToLower(file), "proj") {
		return true // bilinmiyorsa sinyali bekle
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return true
	}
	s := string(data)
	return strings.Contains(s, "Microsoft.NET.Sdk.Web") ||
		strings.Contains(s, "Microsoft.NET.Sdk.Worker") ||
		strings.Contains(s, "Microsoft.NET.Sdk.BlazorWebAssembly") ||
		strings.Contains(s, "Microsoft.NET.Sdk.Razor")
}

// MARK: - JavaScript

type packageJSON struct {
	Name            string            `json:"name"`
	Scripts         map[string]string `json:"scripts"`
	Dependencies    map[string]string `json:"dependencies"`
	DevDependencies map[string]string `json:"devDependencies"`
}

func (p *packageJSON) has(dep string) bool {
	_, a := p.Dependencies[dep]
	_, b := p.DevDependencies[dep]
	return a || b
}

func readPackage(dir string) (*packageJSON, string) {
	found, ok := findUp(dir, "package.json")
	if !ok {
		return &packageJSON{}, dir
	}
	var pkg packageJSON
	if data, err := os.ReadFile(filepath.Join(found, "package.json")); err == nil {
		_ = json.Unmarshal(data, &pkg)
	}
	return &pkg, found
}

// resolvePackageManager: npm run build, npm start, pnpm dev, yarn build, bun run dev …
func resolvePackageManager(pm string, args []string, cwd string) *Resolved {
	args, dir := stripWorkspaceFlags(pm, args, cwd)
	sub := firstPositional(args)
	var script string
	switch {
	case sub == "run" || sub == "run-script":
		script = firstPositional(afterPositional(args, 1))
	case pm == "npm" && sub == "start":
		script = "start"
	case pm == "npm" && (sub == "exec" || sub == "x"):
		return resolveJSTool(pm, stripRunnerFlags(afterPositional(args, 1)), dir)
	case pm != "npm" && (sub == "exec" || sub == "dlx" || sub == "x"):
		return resolveJSTool(pm, stripRunnerFlags(afterPositional(args, 1)), dir)
	case pm != "npm":
		script = sub // pnpm dev, yarn build, bun dev
	}
	if script == "" {
		return nil
	}
	pkg, pkgDir := readPackage(dir)
	body, ok := pkg.Scripts[script]
	if !ok {
		return nil
	}
	r := resolveScript(body, pkgDir, 0)
	if r != nil {
		r.Tool = pm
	}
	return r
}

// stripWorkspaceFlags, alt paket seçen bayrakları çıkarır ve paketin klasörünü döndürür:
// npm -w apps/web, npm --workspace=apps/web, npm --prefix apps/web, pnpm -C apps/web.
func stripWorkspaceFlags(pm string, args []string, cwd string) ([]string, string) {
	flags := map[string]bool{"--prefix": true}
	switch pm {
	case "npm":
		flags["-w"], flags["--workspace"] = true, true
	case "pnpm":
		flags["-C"], flags["--dir"] = true, true
	case "yarn":
		flags["--cwd"] = true
	case "bun":
		flags["--cwd"] = true
	}
	dir := cwd
	var out []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		name, value, hasValue := strings.Cut(a, "=")
		if !flags[name] {
			out = append(out, a)
			continue
		}
		if !hasValue {
			if i+1 >= len(args) {
				break
			}
			i++
			value = args[i]
		}
		candidate := value
		if !filepath.IsAbs(candidate) {
			candidate = filepath.Join(cwd, candidate)
		}
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			dir = candidate
		}
	}
	return out, dir
}

// stripRunnerFlags: npx -y vite build → vite build
func stripRunnerFlags(args []string) []string {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "-") {
			return args[i:]
		}
		if a == "-p" || a == "--package" {
			i++
		}
	}
	return nil
}

var envAssignment = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)

// resolveScript, package.json script'ini parçalarına ayırır ve ilk tanınan aracın profilini
// seçer: "tsc -b && vite build" → vite build. Başka bir script'i çağıran script'ler izlenir.
func resolveScript(body, pkgDir string, depth int) *Resolved {
	if depth > 3 {
		return nil
	}
	for _, segment := range splitScript(body) {
		tokens := segment
		for len(tokens) > 0 && (envAssignment.MatchString(tokens[0]) || tokens[0] == "cross-env" || tokens[0] == "env") {
			tokens = tokens[1:]
		}
		if len(tokens) == 0 {
			continue
		}
		switch name := commandName(tokens[0]); name {
		case "next", "vite", "react-scripts":
			return resolveJSTool(name, tokens, pkgDir)
		case "npx", "bunx":
			if r := resolveJSTool(name, stripRunnerFlags(tokens[1:]), pkgDir); r != nil {
				return r
			}
		case "npm", "pnpm", "yarn", "bun":
			args, dir := stripWorkspaceFlags(name, tokens[1:], pkgDir)
			sub := firstPositional(args)
			script := sub
			if sub == "run" || sub == "run-script" {
				script = firstPositional(afterPositional(args, 1))
			}
			pkg, nested := readPackage(dir)
			if inner, ok := pkg.Scripts[script]; ok {
				if r := resolveScript(inner, nested, depth+1); r != nil {
					return r
				}
			}
		}
	}
	return nil
}

// splitScript, bir shell komutunu &&, ||, ; ve | ile ayrılmış parçalara böler.
func splitScript(s string) [][]string {
	var segments [][]string
	var tokens []string
	var cur strings.Builder
	var quote rune
	flushToken := func() {
		if cur.Len() > 0 {
			tokens = append(tokens, cur.String())
			cur.Reset()
		}
	}
	flushSegment := func() {
		flushToken()
		if len(tokens) > 0 {
			segments = append(segments, tokens)
			tokens = nil
		}
	}
	runes := []rune(s)
	for i := 0; i < len(runes); i++ {
		c := runes[i]
		switch {
		case quote != 0:
			if c == quote {
				quote = 0
			} else {
				cur.WriteRune(c)
			}
		case c == '"' || c == '\'':
			quote = c
		case c == ' ' || c == '\t' || c == '\n':
			flushToken()
		case c == ';':
			flushSegment()
		case c == '&' || c == '|':
			if i+1 < len(runes) && runes[i+1] == c {
				i++
			}
			flushSegment()
		default:
			cur.WriteRune(c)
		}
	}
	flushSegment()
	return segments
}

// resolveJSTool: ["vite", "build"], ["next", "dev", "--turbopack"] …
func resolveJSTool(tool string, tokens []string, dir string) *Resolved {
	if len(tokens) == 0 {
		return nil
	}
	name := commandName(tokens[0])
	p := matchProfile(name, tokens[1:])
	if p == nil {
		return nil
	}
	pkg, pkgDir := readPackage(dir)
	tech := p.Tech
	// Next.js projeleri react'ı da içerir; next önceliklidir. Vite + React → react.
	if tech == "vite" && pkg.has("react") {
		tech = "react"
	}
	project := pkg.Name
	if project == "" {
		project = filepath.Base(pkgDir)
	}
	return &Resolved{Profile: p, Tech: tech, Tool: commandName(tool), Project: project}
}

// MARK: - Yardımcılar

// findUp, dir'den köke doğru name dosyasını içeren ilk klasörü bulur.
func findUp(dir, name string) (string, bool) {
	for {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			return dir, true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", false
		}
		dir = parent
	}
}

// flagValue: "-d ios", "--device-id=ios" ve "--device-id ios" biçimlerini okur.
func flagValue(args []string, names ...string) string {
	for i, a := range args {
		for _, n := range names {
			if a == n && i+1 < len(args) {
				return args[i+1]
			}
			if strings.HasPrefix(a, n+"=") {
				return strings.TrimPrefix(a, n+"=")
			}
		}
	}
	return ""
}
