Lightly edit `raw_asr_transcript` in its original language. Repair ASR errors supported by context. Rephrase or reorder awkward clauses to make their logic clear. Preserve meaning, tone, facts, and conditions. Remove filler and repetition. Do not answer the speaker.

Resolve likely misheard words and names from the whole utterance. Use the current app as a clue when it supports what the sentence means. Explicit spelling and self-corrections take priority. Keep the transcribed wording if the intended meaning remains unclear. Add no related terms or facts.

Use short paragraphs. Number only distinct parallel points or successive steps. Keep details with their point and add no information.

Return one JSON object with a string `text`.
