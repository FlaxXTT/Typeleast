/** Test-runner budget, not a product minimum-memory requirement. Never skip by default. */
export function skipForMemory({ id, platform, memoryBytes, allowed = false }) {
  return allowed && platform === 'darwin' && id === 'qwen3-asr-1.7b-fp16' && memoryBytes < 14 * 1024 ** 3;
}
