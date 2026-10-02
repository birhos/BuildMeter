package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"time"

	"golang.org/x/term"
)

// track, komutu çalıştırır ve bir profile uyuyorsa süresini kaydeder. Profile uymayan
// komutlar (npm install, dotnet test dışı her şey …) olduğu gibi çalıştırılır.
func track(argv []string) int {
	if len(argv) == 0 {
		fmt.Fprintln(os.Stderr, "kullanım: buildmeter track <komut> [argümanlar…]")
		return 2
	}
	path, err := exec.LookPath(argv[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "buildmeter: %s: komut bulunamadı\n", argv[0])
		return 127
	}
	if os.Getenv("BUILDMETER_DISABLE") != "" {
		return passthrough(path, argv, os.Environ())
	}
	cwd, _ := os.Getwd()
	r := resolve(argv, cwd)
	if r == nil {
		return passthrough(path, argv, os.Environ())
	}

	env := os.Environ()
	group := ""
	if r.Tech == "dotnet" {
		// MSBuild hook'u bu id'yi kayıtlarına yazar; uygulama hepsini tek oturumda birleştirir.
		group = newID()
		env = append(env, "BUILDMETER_GROUP="+group)
	}
	if !r.Profile.Records() {
		return passthrough(path, argv, env)
	}

	rec := newRecorder(r, group)
	rec.Start()
	markEditorTerminal(rec.base.ID)

	var rc int
	switch {
	case r.DotnetConsole:
		// Konsol uygulaması "hazır" satırı basmaz: hazır anı, hook'un projeyi derlemeyi
		// bitirdiği andır. Hook kurulu değilse komutun bitişi ölçülür.
		stop := watchHookEnd(group, r.Project, rec)
		rc = runInherit(path, argv, env)
		stop()
		rec.End(statusFor(rc, "success"))
	case r.Profile.WaitsForReady():
		scanner := newLineScanner(func(line string) bool {
			if r.Profile.IsReady(line) {
				rec.End("success")
				return true
			}
			return false
		})
		rc = runWatched(path, argv, env, scanner)
		rec.End(statusFor(rc, "cancelled"))
	default:
		rc = runInherit(path, argv, env)
		rec.End(statusFor(rc, "success"))
	}
	return rc
}

// statusFor, çıkış koduna göre durumu döndürür. Ctrl+C ve sonlandırma sinyalleri iptaldir.
func statusFor(rc int, onSuccess string) string {
	switch rc {
	case 0:
		return onSuccess
	case 130, 137, 143, 0xC000013A, -1073741510:
		return "cancelled"
	}
	return "failed"
}

// markEditorTerminal, editör terminalinde çalışırken terminalde görünmeyen bir OSC dizisi
// basar. Editör eklentisi bu işareti çıktıda görünce aynı komut için kayıt yazmaz.
func markEditorTerminal(id string) {
	if os.Getenv("BUILDMETER_SOURCE") == "" || !term.IsTerminal(int(os.Stdout.Fd())) {
		return
	}
	fmt.Fprintf(os.Stdout, "\x1b]7799;buildmeter;%s\a", id)
}

// watchHookEnd, events.jsonl dosyasını izler ve MSBuild hook'u bu gruptaki projenin
// bitişini yazınca oturumu başarılı olarak kapatır.
func watchHookEnd(group, project string, rec *Recorder) (stop func()) {
	path := eventsPath()
	var offset int64
	if info, err := os.Stat(path); err == nil {
		offset = info.Size()
	}
	done := make(chan struct{})
	go func() {
		ticker := time.NewTicker(250 * time.Millisecond)
		defer ticker.Stop()
		var partial []byte
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
			}
			f, err := os.Open(path)
			if err != nil {
				continue
			}
			_, _ = f.Seek(offset, io.SeekStart)
			data, _ := io.ReadAll(f)
			f.Close()
			offset += int64(len(data))
			partial = append(partial, data...)
			for {
				i := bytes.IndexByte(partial, '\n')
				if i < 0 {
					break
				}
				var e event
				line := partial[:i]
				partial = partial[i+1:]
				if json.Unmarshal(line, &e) == nil && e.Event == "end" && e.Group == group &&
					e.Tool == "msbuild" && e.Project == project {
					rec.End("success")
					return
				}
			}
		}
	}()
	return func() { close(done) }
}

func command(path string, argv, env []string) *exec.Cmd {
	cmd := exec.Command(path)
	cmd.Args = argv
	cmd.Env = env
	// Arka planda kalan alt süreçler (Gradle daemon vb.) çıktıyı açık tutsa da beklemeyi bitir.
	cmd.WaitDelay = time.Second
	return cmd
}
