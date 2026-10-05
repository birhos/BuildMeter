package main

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

// spec/fixtures/ altındaki vakaları macOS uygulamasının testleriyle (FixtureTests.swift)
// aynı şekilde doğrular.

type expectedSession struct {
	Project string   `json:"project"`
	Tech    string   `json:"tech"`
	Source  string   `json:"source"`
	Kind    string   `json:"kind"`
	Status  string   `json:"status"`
	Start   float64  `json:"start"`
	End     *float64 `json:"end"`
}

type expectedCase struct {
	Now    float64 `json:"now"`
	Window struct {
		Start float64 `json:"start"`
		End   float64 `json:"end"`
	} `json:"window"`
	Summary struct {
		Count        int                `json:"count"`
		SuccessCount int                `json:"successCount"`
		MergedTotal  float64            `json:"mergedTotal"`
		SumTotal     float64            `json:"sumTotal"`
		ByTech       map[string]float64 `json:"byTech"`
		BySource     map[string]float64 `json:"bySource"`
		ByProject    map[string]float64 `json:"byProject"`
		ByHost       map[string]float64 `json:"byHost"`
		Sessions     []expectedSession  `json:"sessions"`
	} `json:"summary"`
}

func TestFixtures(t *testing.T) {
	root := filepath.Join("..", "spec", "fixtures")
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) == 0 {
		t.Fatalf("fixture bulunamadı: %s (%v)", root, err)
	}
	for _, entry := range entries {
		// output/ gibi expected.json'u olmayan klasörler vaka değildir.
		if _, err := os.Stat(filepath.Join(root, entry.Name(), "expected.json")); err != nil {
			continue
		}
		t.Run(entry.Name(), func(t *testing.T) { checkFixture(t, filepath.Join(root, entry.Name())) })
	}
}

func checkFixture(t *testing.T, dir string) {
	data, err := os.ReadFile(filepath.Join(dir, "expected.json"))
	if err != nil {
		t.Fatal(err)
	}
	var want expectedCase
	if err := json.Unmarshal(data, &want); err != nil {
		t.Fatal(err)
	}
	start, end := want.Window.Start, want.Window.End
	sessions := loadSessions(dir, want.Now)
	got := summarize(sessions, start, end, want.Now)
	w := want.Summary

	var listed []expectedSession
	for _, s := range sessions {
		if s.Start >= start && s.Start <= end {
			listed = append(listed, expectedSession{s.Project, s.Tech, s.Source, s.Kind, s.Status, s.Start, s.End})
		}
	}
	sort.SliceStable(listed, func(i, j int) bool {
		if listed[i].Start != listed[j].Start {
			return listed[i].Start < listed[j].Start
		}
		return listed[i].Source < listed[j].Source
	})
	if len(listed) != len(w.Sessions) {
		t.Fatalf("oturum sayısı %d, beklenen %d: %+v", len(listed), len(w.Sessions), listed)
	}
	for i := range listed {
		g, e := listed[i], w.Sessions[i]
		if g.Project != e.Project || g.Tech != e.Tech || g.Source != e.Source || g.Kind != e.Kind ||
			g.Status != e.Status || !near(g.Start, e.Start) || !nearPtr(g.End, e.End) {
			t.Errorf("oturum %d:\n got  %+v (end %v)\n want %+v (end %v)", i, g, deref(g.End), e, deref(e.End))
		}
	}

	if got.Count != w.Count || got.SuccessCount != w.SuccessCount {
		t.Errorf("count %d/%d, beklenen %d/%d", got.Count, got.SuccessCount, w.Count, w.SuccessCount)
	}
	if !near(got.MergedTotal, w.MergedTotal) || !near(got.SumTotal, w.SumTotal) {
		t.Errorf("merged %v sum %v, beklenen %v %v", got.MergedTotal, got.SumTotal, w.MergedTotal, w.SumTotal)
	}
	compareMap(t, "byTech", pairsMap(got.ByTech), w.ByTech)
	compareMap(t, "bySource", pairsMap(got.BySource), w.BySource)
	compareMap(t, "byProject", pairsMap(got.ByProject), w.ByProject)

	byHost := map[string]float64{}
	for _, s := range got.Sessions {
		if s.Host == "" {
			continue
		}
		if a, b, ok := s.clipped(start, end, want.Now); ok {
			byHost[s.Host] += b - a
		}
	}
	compareMap(t, "byHost", byHost, w.ByHost)
}

func pairsMap(pairs []Pair) map[string]float64 {
	m := map[string]float64{}
	for _, p := range pairs {
		m[p.Key] = p.Value
	}
	return m
}

func compareMap(t *testing.T, name string, got, want map[string]float64) {
	t.Helper()
	keys := func(m map[string]float64) []string {
		var k []string
		for key := range m {
			k = append(k, key)
		}
		sort.Strings(k)
		return k
	}
	if !reflect.DeepEqual(keys(got), keys(want)) {
		t.Errorf("%s anahtarları %v, beklenen %v", name, got, want)
		return
	}
	for k, v := range want {
		if !near(got[k], v) {
			t.Errorf("%s[%s] = %v, beklenen %v", name, k, got[k], v)
		}
	}
}

func near(a, b float64) bool { return math.Abs(a-b) < 0.001 }

func nearPtr(a, b *float64) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return near(*a, *b)
}

func deref(p *float64) any {
	if p == nil {
		return nil
	}
	return *p
}
