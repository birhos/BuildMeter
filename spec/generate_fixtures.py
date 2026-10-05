"""spec/fixtures/ altındaki ortak fixture vakalarını üretir: python3 spec/generate_fixtures.py"""
import json, os
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fixtures')
D = 1790899200  # pencere başlangıcı (UTC gün başı)
W = {"start": D, "end": D + 86400}
NOW = D + 50000

def ev(event, id, ts, **kw):
    d = {"event": event, "id": id}
    d.update(kw); d["ts"] = ts
    return json.dumps(d, ensure_ascii=False)

def pair(id, start, end, status="success", **kw):
    return [ev("start", id, start, **kw), ev("end", id, end, start=start, status=status, **kw)]

def sess(project, tech, source, kind, status, start, end):
    return {"project": project, "tech": tech, "source": source, "kind": kind,
            "status": status, "start": start, "end": end}

cases = {}

# O-1: tech alanı olmayan eski kayıtlar Flutter sayılır.
t = D + 3600
cases["O-1-legacy"] = dict(
    files={"events.jsonl": pair("a", t, t + 100, source="terminal", kind="run", project="app", device="ios")
           + pair("b", t + 50, t + 120, source="vscode", kind="run", project="app", device="android")
           + pair("c", t + 1000, t + 1060, status="failed", source="terminal", kind="build", project="shop", device="apk")},
    summary=dict(count=3, successCount=2, mergedTotal=180, sumTotal=230,
                 byTech={"flutter": 230}, bySource={"terminal": 160, "vscode": 70},
                 byProject={"app": 170, "shop": 60}, byHost={},
                 sessions=[sess("app", "flutter", "terminal", "run", "success", t, t + 100),
                           sess("app", "flutter", "vscode", "run", "success", t + 50, t + 120),
                           sess("shop", "flutter", "terminal", "build", "failed", t + 1000, t + 1060)]))

# O-2: bilinmeyen tech ve source değerleri "other" olur.
cases["O-2-unknown-values"] = dict(
    files={"events.jsonl": pair("a", t, t + 30, source="zed", tech="rust", tool="cargo", kind="build", project="cli")
           + pair("b", t + 100, t + 140, source="rider", tech="dotnet", tool="msbuild", kind="build", project="Api", device="net8.0|Debug")},
    summary=dict(count=2, successCount=2, mergedTotal=70, sumTotal=70,
                 byTech={"other": 30, "dotnet": 40}, bySource={"other": 30, "rider": 40},
                 byProject={"cli": 30, "Api": 40}, byHost={},
                 sessions=[sess("cli", "other", "other", "build", "success", t, t + 30),
                           sess("Api", "dotnet", "rider", "build", "success", t + 100, t + 140)]))

# O-3: bozuk ve yarım satırlar atlanır, sonrakiler okunur.
lines = ["bu bir json değil", '{"event":"start","id":"x","ts":'] + pair("a", t, t + 45, source="terminal", project="app") \
        + ["", '{"event":"end"}'] + pair("b", t + 100, t + 110, source="terminal", project="app")
cases["O-3-corrupt-lines"] = dict(
    files={"events.jsonl": lines, "_tail": '{"event":"start","id":"half","ts":1790'},
    summary=dict(count=2, successCount=2, mergedTotal=55, sumTotal=55,
                 byTech={"flutter": 55}, bySource={"terminal": 55}, byProject={"app": 55}, byHost={},
                 sessions=[sess("app", "flutter", "terminal", "run", "success", t, t + 45),
                           sess("app", "flutter", "terminal", "run", "success", t + 100, t + 110)]))

# O-4: events.jsonl ve events-<host>.jsonl birlikte; aynı id çift sayılmaz.
dup = pair("same", t, t + 60, source="terminal", project="app")
cases["O-4-multi-file"] = dict(
    files={"events.jsonl": dup,
           "events-win-pc.jsonl": dup + pair("w", t + 200, t + 290, source="visualstudio", tech="dotnet", tool="msbuild",
                                              kind="build", project="Api", host="win-pc", group="g1")},
    summary=dict(count=2, successCount=2, mergedTotal=150, sumTotal=150,
                 byTech={"flutter": 60, "dotnet": 90}, bySource={"terminal": 60, "visualstudio": 90},
                 byProject={"app": 60, "Api": 90}, byHost={"win-pc": 90},
                 sessions=[sess("app", "flutter", "terminal", "run", "success", t, t + 60),
                           sess("Api", "dotnet", "visualstudio", "build", "success", t + 200, t + 290)]))

# O-5: aynı group id'li 5 proje kaydı tek oturum; ilk başlangıçtan son bitişe.
g = []
for i, (s, e) in enumerate([(0, 8), (1, 12), (9, 20), (13, 25), (21, 40)]):
    g += pair(f"p{i}", t + s, t + e, source="terminal", tech="dotnet", tool="msbuild", kind="build",
              project=f"Proj{i}", device="net8.0|Debug", group="sln-1")
cases["O-5-group"] = dict(
    files={"events.jsonl": g},
    summary=dict(count=1, successCount=1, mergedTotal=40, sumTotal=40,
                 byTech={"dotnet": 40}, bySource={"terminal": 40}, byProject={"Proj4": 40}, byHost={},
                 sessions=[sess("Proj4", "dotnet", "terminal", "build", "success", t, t + 40)]))

# O-6: grupsuz MSBuild kayıtları; 1 sn boşlukta birleşir, 5 sn boşlukta ayrı oturum.
m = dict(source="rider", tech="dotnet", tool="msbuild", kind="build", solution="/src/Shop.sln")
cases["O-6-msbuild-gap"] = dict(
    files={"events.jsonl": pair("a", t, t + 10, project="Lib", **m) + pair("b", t + 11, t + 20, project="Api", **m)
           + pair("c", t + 25, t + 30, project="Lib", **m)},
    summary=dict(count=2, successCount=2, mergedTotal=25, sumTotal=25,
                 byTech={"dotnet": 25}, bySource={"rider": 25}, byProject={"Api": 20, "Lib": 5}, byHost={},
                 sessions=[sess("Api", "dotnet", "rider", "build", "success", t, t + 20),
                           sess("Lib", "dotnet", "rider", "build", "success", t + 25, t + 30)]))

# O-7: end satırı gelmeyen MSBuild oturumu: yeni build başlayınca ya da 15 dk sonra failed.
o = dict(tech="dotnet", tool="msbuild", kind="build", project="Api")
cases["O-7-msbuild-open"] = dict(
    files={"events.jsonl": [
        ev("start", "open1", t, source="rider", **o)]
        + pair("next", t + 300, t + 330, source="rider", **o)
        + [ev("start", "open2", NOW - 1200, source="visualstudio", **o),
           ev("start", "open3", NOW - 60, source="terminal", **o)]},
    # Bitişi bilinmeyen başarısız oturumun süresi 0'dır; oturum listesinde görünür,
    # süre toplamlarına ve build sayısına girmez.
    summary=dict(count=2, successCount=1, mergedTotal=90, sumTotal=90,
                 byTech={"dotnet": 90}, bySource={"rider": 30, "terminal": 60},
                 byProject={"Api": 90}, byHost={},
                 sessions=[sess("Api", "dotnet", "rider", "build", "failed", t, t),
                           sess("Api", "dotnet", "rider", "build", "success", t + 300, t + 330),
                           sess("Api", "dotnet", "visualstudio", "build", "failed", NOW - 1200, NOW - 1200),
                           sess("Api", "dotnet", "terminal", "build", "running", NOW - 60, None)]))

# O-8: eşzamanlı dotnet build ve next dev; örtüşme tek sayılır, düz toplam ayrı.
cases["O-8-overlap"] = dict(
    files={"events.jsonl": pair("d", t, t + 60, source="terminal", tech="dotnet", tool="dotnet", kind="build", project="Api")
           + pair("n", t + 30, t + 90, source="vscode", tech="next", tool="npm", kind="dev", project="web")},
    summary=dict(count=2, successCount=2, mergedTotal=90, sumTotal=120,
                 byTech={"dotnet": 60, "next": 60}, bySource={"terminal": 60, "vscode": 60},
                 byProject={"Api": 60, "web": 60}, byHost={},
                 sessions=[sess("Api", "dotnet", "terminal", "build", "success", t, t + 60),
                           sess("web", "next", "vscode", "dev", "success", t + 30, t + 90)]))

# N-2: MSBuild hook'unun gerçek çıktısı (samples/dotnet, terminalden `dotnet build`).
# Üç proje kaydı grupsuz ama aynı çözüm için iç içe; tek oturum olur.
sln = dict(source="terminal", tech="dotnet", tool="msbuild", kind="build", device="net8.0|Debug",
           host="Haydar-MacBook-Pro", solution="/src/samples/dotnet/Sample.sln")
cases["N-2-msbuild-solution"] = dict(
    files={"events.jsonl": [
        ev("start", "lib", t + 0.41, project="Sample.Lib", **sln),
        ev("start", "con", t + 0.44, project="Sample.Console", **sln),
        ev("start", "api", t + 0.52, project="Sample.Api", **sln),
        ev("end", "lib", t + 13.1, project="Sample.Lib", start=t + 0.41, status="success", **sln),
        ev("end", "con", t + 13.3, project="Sample.Console", start=t + 0.44, status="success", **sln),
        ev("end", "api", t + 33.41, project="Sample.Api", start=t + 0.52, status="success", **sln)]},
    summary=dict(count=1, successCount=1, mergedTotal=33, sumTotal=33,
                 byTech={"dotnet": 33}, bySource={"terminal": 33}, byProject={"Sample.Api": 33},
                 byHost={"Haydar-MacBook-Pro": 33},
                 sessions=[sess("Sample.Api", "dotnet", "terminal", "build", "success", t + 0.41, t + 33.41)]))

for name, c in cases.items():
    d = os.path.join(root, name)
    os.makedirs(d, exist_ok=True)
    tail = c["files"].pop("_tail", None)
    for fname, lines in c["files"].items():
        with open(os.path.join(d, fname), "w") as f:
            f.write("\n".join(lines) + "\n" + (tail or ""))
    with open(os.path.join(d, "expected.json"), "w") as f:
        json.dump({"now": NOW, "window": W, "summary": c["summary"]}, f, ensure_ascii=False, indent=2)
        f.write("\n")

