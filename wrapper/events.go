package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// dataDir: BUILDMETER_DATA_DIR ya da ~/.buildmeter (Windows'ta %USERPROFILE%\.buildmeter).
func dataDir() string {
	if d := os.Getenv("BUILDMETER_DATA_DIR"); d != "" {
		return d
	}
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}
	return filepath.Join(home, ".buildmeter")
}

func eventsPath() string { return filepath.Join(dataDir(), "events.jsonl") }

func newID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func nowTS() float64 { return float64(time.Now().UnixMicro()) / 1e6 }

// hostName, MSBuild hook'unun yazdığı $([System.Environment]::MachineName) ile aynı biçimdedir.
func hostName() string {
	h, err := os.Hostname()
	if err != nil {
		return ""
	}
	h, _, _ = strings.Cut(h, ".")
	return h
}

func source() string {
	if s := os.Getenv("BUILDMETER_SOURCE"); s != "" {
		return s
	}
	return "terminal"
}

type event struct {
	Event   string   `json:"event"`
	ID      string   `json:"id"`
	Source  string   `json:"source"`
	Tech    string   `json:"tech"`
	Tool    string   `json:"tool,omitempty"`
	Kind    string   `json:"kind"`
	Project string   `json:"project"`
	Device  string   `json:"device"`
	Host    string   `json:"host,omitempty"`
	Group   string   `json:"group,omitempty"`
	Start   *float64 `json:"start,omitempty"`
	TS      float64  `json:"ts"`
	Status  string   `json:"status,omitempty"`
	PID     int      `json:"pid,omitempty"`
}

// Recorder, bir oturumun start ve end satırlarını yazar. End yalnızca bir kez yazılır.
type Recorder struct {
	base  event
	start float64
	once  sync.Once
	ended bool
	mu    sync.Mutex
}

func newRecorder(r *Resolved, group string) *Recorder {
	return &Recorder{base: event{
		ID: newID(), Source: source(), Tech: r.Tech, Tool: r.Tool, Kind: r.Profile.Kind,
		Project: r.Project, Device: r.Device, Host: hostName(), Group: group,
	}}
}

func (rec *Recorder) Start() {
	rec.start = nowTS()
	e := rec.base
	e.Event, e.TS, e.PID = "start", rec.start, os.Getpid()
	appendEvent(e)
}

func (rec *Recorder) End(status string) {
	rec.once.Do(func() {
		e := rec.base
		start := rec.start
		e.Event, e.Start, e.TS, e.Status = "end", &start, nowTS(), status
		appendEvent(e)
		rec.mu.Lock()
		rec.ended = true
		rec.mu.Unlock()
	})
}

func (rec *Recorder) Ended() bool {
	rec.mu.Lock()
	defer rec.mu.Unlock()
	return rec.ended
}

// appendEvent, satırı tek bir write ile ekler; paralel yazıcılarla satırlar karışmaz.
func appendEvent(e event) {
	data, err := json.Marshal(e)
	if err != nil {
		return
	}
	_ = os.MkdirAll(dataDir(), 0o755)
	f, err := os.OpenFile(eventsPath(), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.Write(append(data, '\n'))
}

// MARK: - Çıktı tarama

var ansi = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][A-Za-z0-9]`)

// LineScanner, komut çıktısını satırlara böler ve her satırı (renk kodları atılmış olarak)
// onLine'a verir. Yeni satır beklemeden yarım satırı da dener, çünkü bazı araçlar
// hazır satırını satır sonu olmadan basar.
type LineScanner struct {
	mu      sync.Mutex
	partial []byte
	onLine  func(string) bool // true dönerse tarama durur
	done    bool
}

func newLineScanner(onLine func(string) bool) *LineScanner {
	return &LineScanner{onLine: onLine}
}

func (s *LineScanner) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.done {
		return len(p), nil
	}
	s.partial = append(s.partial, p...)
	for {
		i := indexLineEnd(s.partial)
		if i < 0 {
			break
		}
		line := string(s.partial[:i])
		s.partial = s.partial[i+1:]
		if s.check(line) {
			return len(p), nil
		}
	}
	if len(s.partial) > 64*1024 {
		s.partial = s.partial[len(s.partial)-4096:]
	}
	if len(s.partial) > 0 {
		s.check(string(s.partial))
	}
	return len(p), nil
}

func (s *LineScanner) check(line string) bool {
	if s.onLine(ansi.ReplaceAllString(line, "")) {
		s.done = true
		s.partial = nil
	}
	return s.done
}

func indexLineEnd(b []byte) int {
	for i, c := range b {
		if c == '\n' || c == '\r' {
			return i
		}
	}
	return -1
}
