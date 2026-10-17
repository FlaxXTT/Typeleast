import fs from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

/**
 * Build a canonical 16 kHz mono PCM16 WAV containing an amplitude-modulated tone,
 * so the recognition path can be exercised with audio that is not silence.
 *
 * Chunk identifiers are built from character codes: a literal four-character
 * string in a generated source file is easy to corrupt (a stray tab or trailing
 * space changes the byte), and a wrong "fmt " id makes DSH reject the file with
 * "Invalid speech WAV" before the model ever runs.
 */
const ID = (...codes) => String.fromCharCode(...codes);
const RIFF = ID(82, 73, 70, 70);
const WAVE = ID(87, 65, 86, 69);
const FMT = ID(102, 109, 116, 32);
const DATA = ID(100, 97, 116, 97);

export function buildToneWav(seconds, frequency = 220, amplitude = 0.3) {
  const samples = Math.round(16000 * seconds);
  const buffer = Buffer.alloc(44 + samples * 2);
  buffer.write(RIFF, 0, 'ascii');
  buffer.writeUInt32LE(36 + samples * 2, 4);
  buffer.write(WAVE, 8, 'ascii');
  buffer.write(FMT, 12, 'ascii');
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(16000, 24);
  buffer.writeUInt32LE(32000, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.write(DATA, 36, 'ascii');
  buffer.writeUInt32LE(samples * 2, 40);
  for (let i = 0; i < samples; i += 1) {
    const envelope = Math.min(1, Math.min(i, samples - i) / 800);
    const value = Math.sin((2 * Math.PI * frequency * i) / 16000) * amplitude * envelope;
    buffer.writeInt16LE(Math.round(value * 32767), 44 + i * 2);
  }
  return buffer;
}

/** Assert the header the host will read, so a bad generator fails loudly here. */
export function assertCanonical(wav) {
  const checks = [
    [wav.length >= 46, 'length >= 46'],
    [wav.toString('ascii', 0, 4) === RIFF, 'RIFF at 0'],
    [wav.toString('ascii', 8, 12) === WAVE, 'WAVE at 8'],
    [wav.toString('ascii', 12, 16) === FMT, 'fmt-space at 12'],
    [wav.readUInt32LE(16) === 16, 'fmt chunk size 16'],
    [wav.readUInt16LE(20) === 1, 'PCM format'],
    [wav.readUInt16LE(22) === 1, 'mono'],
    [wav.readUInt32LE(24) === 16000, '16000 Hz'],
    [wav.readUInt32LE(28) === 32000, 'byte rate'],
    [wav.readUInt16LE(32) === 2, 'block align'],
    [wav.readUInt16LE(34) === 16, '16-bit'],
    [wav.toString('ascii', 36, 40) === DATA, 'data at 36'],
    [wav.readUInt32LE(4) === wav.length - 8, 'RIFF size'],
    [wav.readUInt32LE(40) === wav.length - 44, 'data size'],
    [(wav.length - 44) % 2 === 0, 'even sample bytes'],
  ];
  const failed = checks.filter(([ok]) => !ok).map(([, label]) => label);
  if (failed.length > 0) throw new Error('non-canonical WAV: ' + failed.join(', '));
  return true;
}

if (process.argv[1] && process.argv[1].endsWith('make-tone-wav.mjs')) {
  const out = process.argv[2] ?? join(tmpdir(), 'tone.wav');
  const wav = buildToneWav(2);
  assertCanonical(wav);
  fs.writeFileSync(out, wav);
  console.log('wrote ' + out + ' bytes=' + wav.length + ' fmt=' + JSON.stringify(wav.toString('ascii', 12, 16)));
}
