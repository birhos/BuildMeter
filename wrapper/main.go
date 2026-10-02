// buildmeter: BuildMeter'ın cross-platform terminal wrapper'ı.
//
//	buildmeter track <komut> [argümanlar…]   komutu çalıştırır, profile uyuyorsa süresini kaydeder
//	buildmeter report [--range week] [--tech dotnet] [--csv]
//	buildmeter version
//
// Shell'lerdeki ince shim'ler (buildmeter.sh, buildmeter.ps1) flutter, fvm, npm, pnpm,
// yarn, bun, npx, next, vite ve dotnet komutlarını `buildmeter track` üzerinden çağırır.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// version, release derlemesinde -ldflags "-X main.version=…" ile atanır.
var version = "dev"

func main() {
	// Eski bash wrapper'ının adıyla çağrıldıysa (buildmeter-track <komut> …) track gibi davran.
	if strings.HasPrefix(commandName(filepath.Base(os.Args[0])), "buildmeter-track") {
		os.Exit(track(os.Args[1:]))
	}
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "track":
		os.Exit(track(os.Args[2:]))
	case "report":
		os.Exit(report(os.Args[2:]))
	case "version", "--version", "-v":
		fmt.Println("buildmeter", version)
	case "help", "--help", "-h":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "buildmeter: bilinmeyen komut %q\n\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `Kullanım:
  buildmeter track <komut> [argümanlar…]   Komutu çalıştırır; build ise süresini kaydeder
  buildmeter report [seçenekler]           Bekleme süresi raporunu basar
      --range today|yesterday|week|last7|month|lastmonth   (varsayılan: today)
      --tech flutter|dotnet|react|next|vite
      --csv
  buildmeter version
`)
}
