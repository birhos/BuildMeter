# birhos/homebrew-tap içindeki Formula/buildmeter.rb için Go wrapper'ına geçiş sürümü.
# url/sha256 satırlarını .github/workflows/homebrew.yml günceller.
#
# Eski formula `buildmeter-track` bash betiğini kuruyordu. Yeni formula aynı adı Go
# binary'sine bağlar ve buildmeter.zsh'yi aynı yolda tutar; kullanıcının ~/.zshrc
# satırı değişmeden çalışmaya devam eder.
class Buildmeter < Formula
  desc "Measure how long Flutter, .NET, React and Next.js builds take"
  homepage "https://github.com/birhos/BuildMeter"
  url "https://github.com/birhos/BuildMeter/archive/refs/tags/v1.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/birhos/BuildMeter.git", branch: "main"

  depends_on "go" => :build

  def install
    cd "wrapper" do
      system "go", "build", *std_go_args(ldflags: "-s -w -X main.version=#{version}", output: bin/"buildmeter")
    end
    bin.install_symlink "buildmeter" => "buildmeter-track"
    inreplace "cli/buildmeter.sh", "$HOME/.buildmeter/bin/buildmeter", opt_bin/"buildmeter"
    pkgshare.install "cli/buildmeter.sh"
    pkgshare.install_symlink "buildmeter.sh" => "buildmeter.zsh"
    pkgshare.install "cli/msbuild/BuildMeter.targets"
  end

  def caveats
    <<~EOS
      To track builds automatically, add this to your ~/.zshrc (or ~/.bashrc):
        source #{opt_pkgshare}/buildmeter.zsh

      For .NET builds (dotnet build, Rider), install the MSBuild hook:
        mkdir -p ~/.local/share/Microsoft/MSBuild/Current/Microsoft.Common.targets/ImportAfter
        cp #{opt_pkgshare}/BuildMeter.targets ~/.local/share/Microsoft/MSBuild/Current/Microsoft.Common.targets/ImportAfter/

      Records are written to ~/.buildmeter/events.jsonl. Report: buildmeter report --range week
      The macOS app is available as a cask: brew install --cask birhos/tap/buildmeter
    EOS
  end

  test do
    ENV["BUILDMETER_DATA_DIR"] = testpath/".buildmeter"
    assert_equal "hello", shell_output("#{bin}/buildmeter track echo hello").strip
    assert_equal "hello", shell_output("#{bin}/buildmeter-track echo hello").strip
    assert_match "Build Bekleme Raporu", shell_output("#{bin}/buildmeter report")
  end
end
