import test from "node:test";
import assert from "node:assert/strict";
import { validateWav, WavError } from "../lib/wav.js";

function wav({ sampleRate = 16000, channels = 1, bits = 16, seconds = 0.5, format = 1 } = {}) {
  const samples = Math.round(sampleRate * seconds);
  const buffer = Buffer.alloc(44 + samples * 2);
  buffer.write("RIFF", 0, "ascii");
  buffer.writeUInt32LE(36 + samples * 2, 4);
  buffer.write("WAVE", 8, "ascii");
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(format, 20);
  buffer.writeUInt16LE(channels, 22);
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * channels * (bits / 8), 28);
  buffer.writeUInt16LE(channels * (bits / 8), 32);
  buffer.writeUInt16LE(bits, 34);
  buffer.write("data", 36, "ascii");
  buffer.writeUInt32LE(samples * 2, 40);
  return buffer;
}

test("accepts the canonical recording shape and reports its duration", () => {
  const info = validateWav(wav({ seconds: 2 }), 120);
  assert.equal(info.durationSeconds, 2);
  assert.equal(info.samples, 32000);
});

test("rejects a non-RIFF buffer", () => {
  assert.throws(() => validateWav(Buffer.from("not audio at all, but long enough to pass the length check"), 120), WavError);
});

test("rejects a wrong sample rate", () => {
  assert.throws(() => validateWav(wav({ sampleRate: 44100 }), 120), /16000 Hz/);
});

test("rejects stereo", () => {
  assert.throws(() => validateWav(wav({ channels: 2 }), 120), /mono/);
});

test("rejects non-PCM and non-16-bit audio", () => {
  assert.throws(() => validateWav(wav({ format: 3 }), 120), /uncompressed PCM/);
  assert.throws(() => validateWav(wav({ bits: 8 }), 120), /16-bit/);
});

test("rejects audio longer than the configured ceiling", () => {
  assert.throws(() => validateWav(wav({ seconds: 5 }), 2), /longer than the 2s limit/);
});

test("rejects a header that promises more bytes than were sent", () => {
  const truncated = wav({ seconds: 1 }).subarray(0, 100);
  assert.throws(() => validateWav(truncated, 120), WavError);
});

test("rejects an empty data chunk", () => {
  assert.throws(() => validateWav(wav({ seconds: 0 }), 120), /no samples/);
});

test("a lead-in of silence is added in front, and the result is still canonical", async () => {
  const { withLeadIn, LEAD_IN_SECONDS } = await import("../lib/wav.js");
  const samples = 1600;
  const wav = Buffer.alloc(44 + samples * 2);
  wav.write("RIFF", 0, "ascii"); wav.writeUInt32LE(36 + samples * 2, 4); wav.write("WAVE", 8, "ascii");
  wav.write("fmt ", 12, "ascii"); wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(16000, 24); wav.writeUInt32LE(32000, 28); wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34);
  wav.write("data", 36, "ascii"); wav.writeUInt32LE(samples * 2, 40);
  for (let i = 0; i < samples; i += 1) wav.writeInt16LE(1000, 44 + i * 2);
  const padded = withLeadIn(wav);
  const pad = Math.round(16000 * LEAD_IN_SECONDS) * 2;
  assert.equal(padded.length, wav.length + pad);
  assert.equal(padded.readUInt32LE(40), samples * 2 + pad);
  assert.equal(padded.readUInt32LE(4), padded.length - 8);
  assert.doesNotThrow(() => validateWav(padded, 120));
  assert.equal(padded.readInt16LE(44), 0, "starts with silence");
  assert.equal(padded.readInt16LE(44 + pad), 1000, "then the original samples");
});
