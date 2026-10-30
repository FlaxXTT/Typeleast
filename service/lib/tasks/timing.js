/** Milliseconds shape shared by every result. */
export function timing(started, transcribeMs) {
  const polish = Date.now() - started;
  return { transcribe: Math.round(transcribeMs), polish, total: Math.round(transcribeMs) + polish };
}
