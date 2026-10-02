# Ortak fixture'lar

İstatistik mantığı (MSBuild gruplama, açık kalan oturumların kapatılması, örtüşen
sürelerin birleştirilmesi) macOS uygulamasında (Swift), wrapper'da (Go) ve Windows
uygulamasında (C#) ayrı ayrı yazılır. Üç uygulamanın testleri aynı vakaları doğrular.

Her vaka `fixtures/<vaka>/` altında bir klasördür:

- `events*.jsonl`: Toplayıcıların yazdığı biçimde olay satırları. Klasördeki bütün
  `events*.jsonl` dosyaları ada göre sıralanıp okunur.
- `expected.json`: Beklenen sonuç.

```json
{
  "now": 1790949200,
  "window": { "start": 1790899200, "end": 1790985600 },
  "summary": {
    "count": 2, "successCount": 2,
    "mergedTotal": 90, "sumTotal": 120,
    "byTech": { "dotnet": 60, "next": 60 },
    "bySource": { "terminal": 60, "vscode": 60 },
    "byProject": { "Api": 60, "web": 60 },
    "byHost": {},
    "sessions": [
      { "project": "Api", "tech": "dotnet", "source": "terminal", "kind": "build",
        "status": "success", "start": 1790902800, "end": 1790902860 }
    ]
  }
}
```

- `now`: Hesaplamanın yapıldığı an (açık oturumlar ve 15 dakika kuralı için).
- `window`: Özetin hesaplandığı aralık; süreler bu aralığa kırpılır.
- `sessions`: Birleştirmeden sonra başlangıcı pencere içinde kalan bütün oturumlar,
  başlangıca (eşitse kaynağa) göre sıralı. Süresi 0 olan oturumlar da listede yer alır.
- `count`, `successCount` ve `by*` toplamları yalnızca pencereyle kesişen, süresi
  0'dan büyük oturumları sayar. `byHost` yalnızca `host` alanı yazılmış kayıtları içerir.
- `mergedTotal` örtüşen aralıkları bir kez sayar; `sumTotal` düz toplamdır.

Vakalar `generate_fixtures.py` ile üretilir; yeni vaka eklerken betiği güncelleyip
`python3 spec/generate_fixtures.py` çalıştırın.

| Vaka | Plan testi | Doğrulanan |
| --- | --- | --- |
| `O-1-legacy` | O-1 | `tech` alanı olmayan eski kayıtlar Flutter sayılır |
| `O-2-unknown-values` | O-2 | Bilinmeyen `tech` ve `source` değerleri `other` olur |
| `O-3-corrupt-lines` | O-3 | Bozuk ve yarım satırlar atlanır |
| `O-4-multi-file` | O-4 | `events.jsonl` ve `events-<host>.jsonl` birlikte; aynı id bir kez sayılır |
| `O-5-group` | O-5 | Aynı `group` id'li kayıtlar tek oturum |
| `O-6-msbuild-gap` | O-6 | Grupsuz MSBuild kayıtları 2 sn'den kısa boşlukta birleşir |
| `O-7-msbuild-open` | O-7 | `end` gelmeyen MSBuild oturumu yeni build'de ya da 15 dk sonra `failed` |
| `O-8-overlap` | O-8 | Eşzamanlı build'ler birleştirilmiş toplamda bir kez sayılır |
| `N-2-msbuild-solution` | N-2 | MSBuild hook'unun gerçek solution çıktısı tek oturum olur |
