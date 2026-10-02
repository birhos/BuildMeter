// ~/.buildmeter/events.jsonl yazıcısı. Satır biçimi wrapper/events.go ile aynıdır.

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const DATA_DIR = process.env.BUILDMETER_DATA_DIR || path.join(os.homedir(), '.buildmeter');
const EVENTS = path.join(DATA_DIR, 'events.jsonl');
const HOST = os.hostname().split('.')[0];

function now() {
  return Date.now() / 1000;
}

function write(event) {
  try {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    fs.appendFileSync(EVENTS, JSON.stringify(event) + '\n');
  } catch (err) {
    console.error('[buildmeter]', err);
  }
}

/**
 * Bir oturumun start ve end satırlarını yazar. start ertelenebilir (wrapper'ın işaretini
 * beklerken); end yalnızca bir kez yazılır, start yazılmadıysa önce o yazılır.
 */
class Recorder {
  /** @param {{source: string, tech: string, tool?: string, kind: string, project: string, device?: string}} fields */
  constructor(fields, start = now()) {
    this.base = {
      id: crypto.randomUUID().replace(/-/g, ''),
      source: fields.source,
      tech: fields.tech,
      ...(fields.tool ? { tool: fields.tool } : {}),
      kind: fields.kind,
      project: fields.project,
      device: fields.device || '',
      host: HOST,
    };
    this.start = start;
    this.started = false;
    this.ended = false;
  }

  emitStart() {
    if (this.started || this.ended) return;
    this.started = true;
    write({ event: 'start', ...this.base, ts: this.start, pid: process.pid });
  }

  end(status) {
    if (this.ended) return;
    this.emitStart();
    this.ended = true;
    write({ event: 'end', ...this.base, start: this.start, ts: now(), status });
  }

  /** Kaydı hiç yazmadan bırakır; start yazıldıysa uygulama oturumu listeden siler. */
  discard() {
    if (this.ended) return;
    if (this.started) write({ event: 'discard', id: this.base.id, ts: now() });
    this.ended = true;
  }
}

module.exports = { Recorder, EVENTS, now };
