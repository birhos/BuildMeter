package main

import (
	_ "embed"
	"encoding/json"
	"regexp"
	"strings"
)

//go:embed profiles.json
var profilesJSON []byte

// Profile, bir aracın bir alt komutunun nasıl ölçüleceğini tanımlar.
type Profile struct {
	ID       string     `json:"id"`
	Tech     string     `json:"tech"`
	Kind     string     `json:"kind"`
	Commands [][]string `json:"commands"`
	Ready    []string   `json:"ready"`
	Record   *bool      `json:"record"`

	ready []*regexp.Regexp
}

// Records, wrapper'ın kendi kaydını yazıp yazmayacağını söyler.
func (p *Profile) Records() bool { return p.Record == nil || *p.Record }

// WaitsForReady, ölçümün bir çıktı satırında mı yoksa komutun bitişinde mi biteceğini söyler.
func (p *Profile) WaitsForReady() bool { return len(p.ready) > 0 }

// IsReady, satırın profilin hazır sinyallerinden birini içerip içermediğini döndürür.
func (p *Profile) IsReady(line string) bool {
	for _, re := range p.ready {
		if re.MatchString(line) {
			return true
		}
	}
	return false
}

var profiles = mustLoadProfiles(profilesJSON)

func mustLoadProfiles(data []byte) []*Profile {
	var file struct {
		Profiles []*Profile `json:"profiles"`
	}
	if err := json.Unmarshal(data, &file); err != nil {
		panic("profiles.json: " + err.Error())
	}
	for _, p := range file.Profiles {
		for _, expr := range p.Ready {
			p.ready = append(p.ready, regexp.MustCompile(expr))
		}
	}
	return file.Profiles
}

// matchProfile, araç ve argümanlarına uyan profili döndürür. Önce tam eşleşmeler,
// sonra "*" jokerleri denenir.
func matchProfile(tool string, args []string) *Profile {
	sub := firstPositional(args)
	var wildcard *Profile
	for _, p := range profiles {
		for _, c := range p.Commands {
			if len(c) != 2 || c[0] != tool {
				continue
			}
			if c[1] == sub {
				return p
			}
			if c[1] == "*" && sub != "" && wildcard == nil {
				wildcard = p
			}
		}
	}
	if wildcard != nil && !isKnownSubcommand(tool, sub) {
		return wildcard
	}
	return nil
}

// isKnownSubcommand, alt komutun aracın herhangi bir profilinde açıkça geçip geçmediğini
// ya da profili olmayan bilinen bir alt komut olup olmadığını söyler.
func isKnownSubcommand(tool, sub string) bool {
	for _, p := range profiles {
		for _, c := range p.Commands {
			if len(c) == 2 && c[0] == tool && c[1] == sub {
				return true
			}
		}
	}
	untracked := map[string][]string{
		"vite": {"preview", "optimize"},
	}
	for _, s := range untracked[tool] {
		if s == sub {
			return true
		}
	}
	return false
}

func firstPositional(args []string) string {
	for _, a := range args {
		if a == "--" {
			return ""
		}
		if !strings.HasPrefix(a, "-") {
			return a
		}
	}
	return ""
}
