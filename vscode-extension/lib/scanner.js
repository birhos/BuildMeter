// Komut çıktısını satırlara böler, renk kodlarını atar ve her satırı onLine'a verir.
// wrapper/events.go içindeki LineScanner ile aynı davranır.

const ansi = /\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][A-Za-z0-9]/g;

/** Wrapper'ın editör terminalinde bastığı işaret: ESC ] 7799 ; buildmeter ; <id> BEL */
const wrapperMarker = /\x1b\]7799;buildmeter;[0-9a-f]+\x07/;

class LineScanner {
  /** @param {(line: string) => boolean} onLine true dönerse tarama durur */
  constructor(onLine) {
    this.onLine = onLine;
    this.partial = '';
    this.done = false;
  }

  write(chunk) {
    if (this.done) return;
    this.partial += chunk;
    for (;;) {
      const i = this.partial.search(/[\r\n]/);
      if (i < 0) break;
      const line = this.partial.slice(0, i);
      this.partial = this.partial.slice(i + 1);
      if (this.check(line)) return;
    }
    if (this.partial.length > 64 * 1024) this.partial = this.partial.slice(-4096);
    // Bazı araçlar hazır satırını satır sonu olmadan basar.
    if (this.partial) this.check(this.partial);
  }

  check(line) {
    if (this.onLine(line.replace(ansi, ''))) {
      this.done = true;
      this.partial = '';
    }
    return this.done;
  }
}

/** Renk ve kontrol dizileri atıldıktan sonra görünür bir karakter kalıyor mu? */
function hasVisibleText(data) {
  return /\S/.test(data.replace(ansi, '').replace(/\x1b\][^\x07]*\x07?/g, ''));
}

module.exports = { LineScanner, wrapperMarker, hasVisibleText };
