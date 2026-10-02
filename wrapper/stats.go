package main

// Bu dosya macOS uygulamasındaki EventLog.swift ve Stats.swift ile aynı hesaplamayı yapar.
// İki uygulama da spec/fixtures/ altındaki vakalarla doğrulanır; mantık değişirse ikisi
// birlikte değişmelidir.

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

var knownSources = map[string]bool{
	"terminal": true, "vscode": true, "cursor": true, "antigravity": true,
	"rider": true, "visualstudio": true,
}

var knownTechs = map[string]bool{"flutter": true, "dotnet": true, "react": true, "next": true, "vite": true}

// Session, bir build, çalıştırma ya da debug oturumudur. Zamanlar Unix saniyesidir.
type Session struct {
	ID, Source, Tech, Tool, Group, Host, Solution string
	Kind, Project, Device, Status                 string
	Start                                         float64
	End                                           *float64
	PID                                           int
}

func (s *Session) Active() bool  { return s.End == nil }
func (s *Session) MSBuild() bool { return s.Tool == "msbuild" }
func (s *Session) endOr(now float64) float64 {
	if s.End != nil {
		return *s.End
	}
	return now
}

// clipped, oturumun [start, end) penceresiyle kesişiminin süresini döndürür; kesişim yoksa false.
func (s *Session) clipped(start, end, now float64) (float64, float64, bool) {
	a, b := max(s.Start, start), min(s.endOr(now), end)
	return a, b, b > a
}

type rawEvent struct {
	Event    *string  `json:"event"`
	ID       *string  `json:"id"`
	TS       *float64 `json:"ts"`
	Source   string   `json:"source"`
	Tech     string   `json:"tech"`
	Tool     string   `json:"tool"`
	Group    string   `json:"group"`
	Host     string   `json:"host"`
	Solution string   `json:"solution"`
	Kind     string   `json:"kind"`
	Project  string   `json:"project"`
	Device   string   `json:"device"`
	Start    *float64 `json:"start"`
	Status   string   `json:"status"`
	PID      int      `json:"pid"`
}

// EventLog, olay satırlarından ham oturumları üretir.
type EventLog struct {
	ByID map[string]*Session
}

func newEventLog() *EventLog { return &EventLog{ByID: map[string]*Session{}} }

// Ingest, tam satırları uygular; bozuk satırlar atlanır.
func (l *EventLog) Ingest(data []byte) {
	for _, line := range bytes.Split(data, []byte{'\n'}) {
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var e rawEvent
		if json.Unmarshal(line, &e) != nil || e.Event == nil || e.ID == nil || e.TS == nil {
			continue
		}
		l.apply(&e)
	}
}

func (l *EventLog) apply(e *rawEvent) {
	id, ts := *e.ID, *e.TS
	switch *e.Event {
	case "start":
		if s, ok := l.ByID[id]; ok && s.End != nil {
			return
		}
		l.ByID[id] = sessionFrom(e, ts)
	case "end":
		s, ok := l.ByID[id]
		if !ok {
			start := ts
			if e.Start != nil {
				start = *e.Start
			}
			s = sessionFrom(e, start)
		}
		if e.Start != nil {
			s.Start = *e.Start
		}
		if e.Device != "" {
			s.Device = e.Device
		}
		if e.Project != "" {
			s.Project = e.Project
		}
		if e.Group != "" {
			s.Group = e.Group
		}
		s.PID = 0
		end := max(ts, s.Start)
		s.End = &end
		switch e.Status {
		case "success", "failed", "cancelled":
			s.Status = e.Status
		default:
			s.Status = "failed"
		}
		l.ByID[id] = s
	case "discard":
		delete(l.ByID, id)
	}
}

func sessionFrom(e *rawEvent, start float64) *Session {
	s := &Session{
		ID: *e.ID, Source: "other", Tech: "flutter", Tool: e.Tool, Group: e.Group, Host: e.Host,
		Solution: e.Solution, Kind: e.Kind, Project: e.Project, Device: e.Device,
		Start: start, Status: "running", PID: e.PID,
	}
	if knownSources[e.Source] {
		s.Source = e.Source
	}
	if e.Tech != "" {
		s.Tech = e.Tech
		if !knownTechs[e.Tech] {
			s.Tech = "other"
		}
	}
	if s.Kind == "" {
		s.Kind = "run"
	}
	if s.Project == "" {
		s.Project = "?"
	}
	return s
}

// MARK: - Birleştirme

const (
	msbuildGap       = 2.0
	msbuildOpenLimit = 15 * 60.0
)

// MergeSessions, SessionMerger.sessions(from:now:) ile aynı kuralları uygular.
func MergeSessions(raw []*Session, now float64) []*Session {
	var result []*Session
	groups := map[string][]*Session{}
	msbuild := map[string][]*Session{}
	var groupOrder, msbuildOrder []string

	for _, s := range raw {
		switch {
		case s.Group != "":
			if _, ok := groups[s.Group]; !ok {
				groupOrder = append(groupOrder, s.Group)
			}
			groups[s.Group] = append(groups[s.Group], s)
		case s.MSBuild():
			key := s.Source + "|" + s.Host + "|" + s.Solution
			if _, ok := msbuild[key]; !ok {
				msbuildOrder = append(msbuildOrder, key)
			}
			msbuild[key] = append(msbuild[key], s)
		default:
			result = append(result, s)
		}
	}

	for _, g := range groupOrder {
		result = append(result, merge(groups[g], "group:"+g, now, false))
	}
	for _, key := range msbuildOrder {
		members := msbuild[key]
		sort.SliceStable(members, func(i, j int) bool { return members[i].Start < members[j].Start })
		var cluster []*Session
		activityEnd := 0.0
		for _, s := range members {
			if len(cluster) > 0 && s.Start > activityEnd+msbuildGap {
				result = append(result, merge(cluster, cluster[0].ID, now, true))
				cluster, activityEnd = nil, 0
			}
			cluster = append(cluster, s)
			activityEnd = max(activityEnd, s.endOr(s.Start))
		}
		if len(cluster) > 0 {
			result = append(result, merge(cluster, cluster[0].ID, now, false))
		}
	}
	return result
}

func merge(members []*Session, id string, now float64, closesOpen bool) *Session {
	if len(members) == 1 && !closesOpen && !(members[0].MSBuild() && members[0].Active()) {
		return members[0]
	}
	var primary *Session
	for _, m := range members {
		if !m.MSBuild() {
			primary = m
			break
		}
	}
	if primary == nil {
		for _, m := range members {
			if primary == nil || m.endOr(m.Start) > primary.endOr(primary.Start) {
				primary = m
			}
		}
	}
	merged := *primary
	merged.ID, merged.End, merged.Status, merged.PID = id, nil, "running", 0
	merged.Start = members[0].Start
	for _, m := range members {
		merged.Start = min(merged.Start, m.Start)
	}
	if merged.Device == "" {
		// Wrapper cihaz bilmez; MSBuild kaydının hedef çatısı ve konfigürasyonu kullanılır.
		for _, m := range members {
			if m.Device != "" {
				merged.Device = m.Device
			}
		}
	}

	if !primary.MSBuild() {
		merged.End, merged.Status, merged.PID = primary.End, primary.Status, primary.PID
		return &merged
	}

	activityEnd, hasOpen, failed, cancelled := 0.0, false, false, false
	for _, m := range members {
		activityEnd = max(activityEnd, m.endOr(m.Start))
		hasOpen = hasOpen || m.Active()
		failed = failed || m.Status == "failed"
		cancelled = cancelled || m.Status == "cancelled"
	}
	if hasOpen && !closesOpen && now-activityEnd < msbuildOpenLimit {
		return &merged
	}
	merged.End = &activityEnd
	switch {
	case hasOpen || failed:
		merged.Status = "failed"
	case cancelled:
		merged.Status = "cancelled"
	default:
		merged.Status = "success"
	}
	return &merged
}

// MARK: - Özet

type Summary struct {
	Sessions     []*Session
	MergedTotal  float64
	SumTotal     float64
	Count        int
	SuccessCount int
	Longest      float64
	Average      float64
	ByTech       []Pair
	BySource     []Pair
	ByProject    []Pair
}

type Pair struct {
	Key   string
	Value float64
}

func summarize(sessions []*Session, start, end, now float64) Summary {
	var sum Summary
	var intervals [][2]float64
	byTech, bySource, byProject := map[string]float64{}, map[string]float64{}, map[string]float64{}
	var durations []float64
	for _, s := range sessions {
		a, b, ok := s.clipped(start, end, now)
		if !ok {
			continue
		}
		sum.Sessions = append(sum.Sessions, s)
		intervals = append(intervals, [2]float64{a, b})
		d := b - a
		sum.SumTotal += d
		byTech[s.Tech] += d
		bySource[s.Source] += d
		byProject[s.Project] += d
		if s.Status == "success" {
			sum.SuccessCount++
		}
		if !s.Active() {
			durations = append(durations, *s.End-s.Start)
		}
	}
	sum.Count = len(sum.Sessions)
	sum.MergedTotal = mergedDuration(intervals)
	for _, d := range durations {
		sum.Longest = max(sum.Longest, d)
		sum.Average += d
	}
	if len(durations) > 0 {
		sum.Average /= float64(len(durations))
	}
	sum.ByTech, sum.BySource, sum.ByProject = sortedPairs(byTech), sortedPairs(bySource), sortedPairs(byProject)
	return sum
}

func sortedPairs(m map[string]float64) []Pair {
	pairs := make([]Pair, 0, len(m))
	for k, v := range m {
		pairs = append(pairs, Pair{k, v})
	}
	sort.Slice(pairs, func(i, j int) bool {
		if pairs[i].Value != pairs[j].Value {
			return pairs[i].Value > pairs[j].Value
		}
		return pairs[i].Key < pairs[j].Key
	})
	return pairs
}

// mergedDuration, örtüşen aralıkları birleştirip toplam süreyi döndürür.
func mergedDuration(intervals [][2]float64) float64 {
	sort.Slice(intervals, func(i, j int) bool { return intervals[i][0] < intervals[j][0] })
	total := 0.0
	var cur *[2]float64
	for i := range intervals {
		iv := intervals[i]
		if cur != nil && iv[0] <= cur[1] {
			cur[1] = max(cur[1], iv[1])
			continue
		}
		if cur != nil {
			total += cur[1] - cur[0]
		}
		cur = &iv
	}
	if cur != nil {
		total += cur[1] - cur[0]
	}
	return total
}

// loadSessions, veri klasöründeki bütün events*.jsonl dosyalarını okur ve birleştirilmiş
// oturumları döndürür.
func loadSessions(dir string, now float64) []*Session {
	log := newEventLog()
	entries, _ := os.ReadDir(dir)
	var names []string
	for _, e := range entries {
		if n := e.Name(); strings.HasPrefix(n, "events") && strings.HasSuffix(n, ".jsonl") {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	for _, n := range names {
		if data, err := os.ReadFile(filepath.Join(dir, n)); err == nil {
			log.Ingest(data)
		}
	}
	raw := make([]*Session, 0, len(log.ByID))
	for _, s := range log.ByID {
		raw = append(raw, s)
	}
	return MergeSessions(raw, now)
}
