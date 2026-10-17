/**
 * Canonical WAV validation for the dictation endpoint.
 *
 * Only one shape is accepted, because only one shape is produced: the browser
 * recorder emits and the host service accepts 16 kHz mono 16-bit PCM RIFF/WAVE.
 * Anything else is rejected before it reaches the recogniser.
 *
 * @module dsh-voice-polish/wav
 */

export const WAV_HEADER_BYTES = 44;
export const SAMPLE_RATE = 16000;
export const BYTES_PER_SECOND = SAMPLE_RATE * 2;

export class WavError extends Error {
  constructor(message) {
    super(message);
    this.name = "WavError";
    this.code = "invalid-audio";
  }
}

/**
 * Validate a canonical 16 kHz mono PCM16 WAV and report its duration.
 * @param {Buffer} audio - request body.
 * @param {number} maxDurationSeconds - configured duration ceiling.
 * @returns {{durationSeconds: number, samples: number}}
 * @throws {WavError} when the bytes are not that shape.
 */
export function validateWav(audio, maxDurationSeconds) {
  if (!Buffer.isBuffer(audio) || audio.length < WAV_HEADER_BYTES) {
    throw new WavError("audio must be a RIFF/WAVE buffer of at least 44 bytes");
  }
  if (audio.toString("ascii", 0, 4) !== "RIFF" || audio.toString("ascii", 8, 12) !== "WAVE") {
    throw new WavError("audio is not a RIFF/WAVE container");
  }
  const riffSize = audio.readUInt32LE(4);
  if (riffSize + 8 > audio.length) throw new WavError("WAV RIFF size exceeds the received bytes");
  const audioFormat = audio.readUInt16LE(20);
  const channels = audio.readUInt16LE(22);
  const sampleRate = audio.readUInt32LE(24);
  const bitsPerSample = audio.readUInt16LE(34);
  if (audioFormat !== 1) throw new WavError("audio must be uncompressed PCM");
  if (channels !== 1) throw new WavError("audio must be mono");
  if (sampleRate !== SAMPLE_RATE) throw new WavError(`audio must be ${SAMPLE_RATE} Hz`);
  if (bitsPerSample !== 16) throw new WavError("audio must be 16-bit");
  const dataBytes = audio.readUInt32LE(40);
  if (dataBytes === 0) throw new WavError("audio contains no samples");
  if (WAV_HEADER_BYTES + dataBytes > audio.length) throw new WavError("WAV data chunk exceeds the received bytes");
  const durationSeconds = dataBytes / BYTES_PER_SECOND;
  if (durationSeconds > maxDurationSeconds) {
    throw new WavError(`audio is ${durationSeconds.toFixed(1)}s, longer than the ${maxDurationSeconds}s limit`);
  }
  return { durationSeconds, samples: dataBytes / 2 };
}

/** Silence added before recognition so the first syllable is never cut off. */
export const LEAD_IN_SECONDS = 0.3;

/**
 * Prefix a canonical 16 kHz mono PCM16 WAV with silence.
 *
 * Measured with synthetic speech that starts at the first sample: SenseVoice's
 * voice-activity detection dropped the opening syllable ("我们" -> "们",
 * "帮我" -> "我"), and recognised it fully once 0.4 s of silence came first. Real
 * dictations start that abruptly whenever someone speaks the moment they press
 * the key, so every recording gets a short lead-in.
 *
 * @param {Buffer} audio - a WAV that passed validateWav().
 * @param {number} seconds - silence to add.
 * @returns {Buffer} a new canonical WAV.
 */
export function withLeadIn(audio, seconds = LEAD_IN_SECONDS) {
  const dataBytes = audio.readUInt32LE(40);
  const padBytes = Math.round(SAMPLE_RATE * seconds) * 2;
  const out = Buffer.alloc(WAV_HEADER_BYTES + padBytes + dataBytes);
  audio.copy(out, 0, 0, WAV_HEADER_BYTES);
  out.writeUInt32LE(36 + padBytes + dataBytes, 4);
  out.writeUInt32LE(padBytes + dataBytes, 40);
  audio.copy(out, WAV_HEADER_BYTES + padBytes, WAV_HEADER_BYTES, WAV_HEADER_BYTES + dataBytes);
  return out;
}
