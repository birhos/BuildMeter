//go:build windows

package main

import (
	"io"
	"os"
	"os/exec"
	"os/signal"

	"golang.org/x/sys/windows"
)

// Windows'ta exec yoktur: komut alt süreç olarak çalışır ve çıkış kodu aktarılır.
func passthrough(path string, argv, env []string) int {
	return runInherit(path, argv, env)
}

func runInherit(path string, argv, env []string) int {
	cmd := command(path, argv, env)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	defer ignoreInterrupts()()
	_ = cmd.Run()
	return exitCode(cmd)
}

// runWatched: ConPTY yerine pipe + tee kullanılır. Girdi konsoldan doğrudan okunur, bu yüzden
// flutter run kısayolları çalışır; çıktı terminal olmadığı için bazı araçlar renkleri kapatabilir.
func runWatched(path string, argv, env []string, scanner io.Writer) int {
	cmd := command(path, argv, env)
	cmd.Stdin = os.Stdin
	cmd.Stdout = io.MultiWriter(os.Stdout, scanner)
	cmd.Stderr = io.MultiWriter(os.Stderr, scanner)
	defer ignoreInterrupts()()
	_ = cmd.Run()
	return exitCode(cmd)
}

func ignoreInterrupts() (restore func()) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, os.Interrupt)
	return func() { signal.Stop(ch) }
}

func exitCode(cmd *exec.Cmd) int {
	if cmd.ProcessState == nil {
		return 127
	}
	return cmd.ProcessState.ExitCode()
}

// enableUTF8Console, rapor çıktısındaki Türkçe karakterlerin konsolda doğru görünmesini sağlar.
func enableUTF8Console() {
	_ = windows.SetConsoleOutputCP(65001) // UTF-8
}
