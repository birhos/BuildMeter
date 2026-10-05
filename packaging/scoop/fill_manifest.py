#!/usr/bin/env python3
"""Scoop manifest şablonunu bir release için doldurur.

Kullanım: fill_manifest.py <şablon> <checksums.txt> <sürüm> <çıktı>

Url'ler şablonun autoupdate bölümünden ($version yerine sürüm konarak), hash'ler
checksums.txt'den alınır. Böylece elle düzenlenen tek yer autoupdate bölümüdür.
"""

import json
import sys


def main() -> int:
    template, checksums, version, output = sys.argv[1:5]
    version = version.removeprefix("v")
    sums = {}
    with open(checksums, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2:
                sums[parts[1].lstrip("*")] = parts[0].lower()

    with open(template, encoding="utf-8") as f:
        manifest = json.load(f)
    manifest.pop("##", None)
    manifest["version"] = version
    for arch, spec in manifest["autoupdate"]["architecture"].items():
        urls = [u.replace("$version", version) for u in spec["url"]]
        assets = [u.split("#/")[0].rsplit("/", 1)[1] for u in urls]
        missing = [a for a in assets if a not in sums]
        if missing:
            print(f"checksums.txt içinde yok: {', '.join(missing)}", file=sys.stderr)
            return 1
        manifest["architecture"][arch]["url"] = urls
        manifest["architecture"][arch]["hash"] = [sums[a] for a in assets]

    with open(output, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=4, ensure_ascii=False)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
