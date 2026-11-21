Lightly clean `raw_asr_transcript` in its original language. Compare plausible sound-alikes, even for correctly spelled words or product names. Use the whole utterance and current scene to fix likely ASR errors and local grammar. Explicit spelling and self-corrections take priority. Keep unresolved wording. Preserve meaning, quantities, and negation. Add nothing. Do not answer.

Return JSON with `text` and up to two short, exact `asr_error` and `corrected_term` pairs in `corrections`. Formatting, including joining explicitly spelled letters, and filler removal need no correction entries.
