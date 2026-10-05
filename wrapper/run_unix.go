//go:build !windows

package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"

	"github.com/creack/pty"
	"golang.org/x/term"
)

// passthrough, wrapper sürecini komutla değiştirir; ek gecikme ve ara süreç kalmaz.
func passthrough(path string, argv, env []string) int {
	err := syscall.Exec(path, argv, env)
	fmt.Fprintf(os.Stderr, "buildmeter: %s: %v\n", argv[0], err)
	return 126
}

// runInherit, komutu terminali paylaşarak çalıştırır. Ctrl+C terminalden zaten bütün süreç
// grubuna gider: wrapper onu yutar ve kaydı yazmak için ayakta kalır. Dışarıdan wrapper'a
// gönderilen SIGTERM ve SIGHUP komuta iletilir.
func runInherit(path string, argv, env []string) int {
	cmd := command(path, argv, env)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	runForwarding(cmd, syscall.SIGTERM, syscall.SIGHUP)
	return exitCode(cmd)
}

// runWatched, komutun çıktısını hem terminale hem scanner'a verir. Etkileşimli terminalde
// gerçek bir pty açılır: renkler ve flutter run'ın r/R/q kısayolları aynen çalışır.
func runWatched(path string, argv, env []string, scanner io.Writer) int {
	if term.IsTerminal(int(os.Stdin.Fd())) && term.IsTerminal(int(os.Stdout.Fd())) {
		if rc, ok := runInPTY(path, argv, env, scanner); ok {
			return rc
		}
	}
	return runPiped(path, argv, env, scanner)
}

func runInPTY(path string, argv, env []string, scanner io.Writer) (int, bool) {
	cmd := command(path, argv, env)
	signals := make(chan os.Signal, 4)
	// Komut kendi pty oturumunda çalışır; wrapper'a gelen sinyaller ona ulaşmaz, iletilir.
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(signals)
	ptmx, err := pty.Start(cmd)
	if err != nil {
		return 0, false
	}
	defer ptmx.Close()
	go forward(signals, cmd, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)

	winch := make(chan os.Signal, 1)
	signal.Notify(winch, syscall.SIGWINCH)
	defer signal.Stop(winch)
	go func() {
		for range winch {
			_ = pty.InheritSize(os.Stdin, ptmx)
		}
	}()
	winch <- syscall.SIGWINCH

	if old, err := term.MakeRaw(int(os.Stdin.Fd())); err == nil {
		defer term.Restore(int(os.Stdin.Fd()), old)
	}
	go func() { _, _ = io.Copy(ptmx, os.Stdin) }()

	copied := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.MultiWriter(os.Stdout, scanner), ptmx)
		close(copied)
	}()
	_ = cmd.Wait()
	// Çıkışta kalan son çıktıyı bas; pty'yi açık tutan torun süreçleri bekleme.
	select {
	case <-copied:
	case <-time.After(500 * time.Millisecond):
	}
	return exitCode(cmd), true
}

func runPiped(path string, argv, env []string, scanner io.Writer) int {
	cmd := command(path, argv, env)
	cmd.Stdin = os.Stdin
	cmd.Stdout = io.MultiWriter(os.Stdout, scanner)
	cmd.Stderr = io.MultiWriter(os.Stderr, scanner)
	runForwarding(cmd, syscall.SIGTERM, syscall.SIGHUP)
	return exitCode(cmd)
}

// runForwarding, komutu çalıştırır; SIGINT'i yutar, verilen sinyalleri komuta iletir.
func runForwarding(cmd *exec.Cmd, signals ...os.Signal) {
	ch := make(chan os.Signal, 4)
	signal.Notify(ch, append([]os.Signal{os.Interrupt}, signals...)...)
	defer signal.Stop(ch)
	if err := cmd.Start(); err != nil {
		return
	}
	go forward(ch, cmd, signals...)
	_ = cmd.Wait()
}

func forward(ch <-chan os.Signal, cmd *exec.Cmd, signals ...os.Signal) {
	for sig := range ch {
		for _, s := range signals {
			if sig == s && cmd.Process != nil {
				_ = cmd.Process.Signal(sig)
			}
		}
	}
}

func exitCode(cmd *exec.Cmd) int {
	if cmd.ProcessState == nil {
		return 127
	}
	if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	return cmd.ProcessState.ExitCode()
}

// enableUTF8Console: Unix terminalleri zaten UTF-8 kullanır.
func enableUTF8Console() {}
