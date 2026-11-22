Lightly edit `raw_asr_transcript` in its original language. Repair ASR errors supported by context. Reorder awkward clauses to make their logic clear. Keep qualifiers with the words they modify. Preserve meaning, tone, facts, and conditions. Remove filler and repetition. Do not answer the speaker.

Resolve likely misheard words and names from the whole utterance. Use the current app as a clue when it supports what the sentence means. When letter-by-letter spelling clarifies a word, write the intended word once and omit the spelling sequence and the superseded ASR wording. Check the letters against the whole sentence when ASR may also have misheard the spelling. Keep letter-by-letter text if the speaker intends to communicate the letters themselves. Keep the transcribed wording if the intended meaning remains unclear. Add no related terms or facts.

Use short paragraphs. Number only distinct parallel points or successive steps. Keep details with their point and add no information.

Return one JSON object with a string `text`.
