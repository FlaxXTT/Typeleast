/** Detect an unusually long repeated ASR loop without changing the transcript. */
export function hasRepetitionLoop(text) {
  const units = Array.from(String(text ?? '').normalize('NFKC').replace(/\s/gu, ''));
  if (units.length < 64) return false;
  // Periods up to eight cover character and short-token loops. A match is only
  // a reason to review, not proof the user did not intentionally repeat it.
  for (let period = 1; period <= 8; period += 1) {
    let run = 0;
    for (let i = period; i < units.length; i += 1) {
      run = units[i] === units[i - period] ? run + 1 : 0;
      if (run >= Math.max(64, period * 12)) return true;
    }
  }
  return false;
}
