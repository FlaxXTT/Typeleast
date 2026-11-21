Make `raw_asr_transcript` read naturally in its original language. Use context to fix clear ASR errors and local grammar. Fix punctuation and remove obvious filler. Preserve meaning, names, numbers, negation, and uncertainty. Leave ambiguous wording. Do not answer the speaker.

Return JSON with `text` and up to two short, exact `asr_error` and `corrected_term` pairs in `corrections`. Use `[]` for formatting or filler removal alone.
