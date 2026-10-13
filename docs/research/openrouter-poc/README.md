# OpenRouter public catalogue shape check

Research only, captured 2026-10-12. No production code or dependencies.

Exactly three unauthenticated API GETs were made, with a 30-second timeout:

1. `https://openrouter.ai/api/v1/models`
2. `https://openrouter.ai/api/v1/models?output_modalities=all`
3. `https://openrouter.ai/api/v1/models?output_modalities=all&sort=newest&limit=3`

No automatic retries, inference, authentication, key inspection or mutation. The
third call verifies first-page sorting and the next-link shape; it does **not**
fetch the next page. Documentation/source browsing was additional read-only traffic.

`catalogue-evidence.json` contains counts, raw-body SHA-256/size metadata, selected
unaltered field values and allowlisted response headers. It is a **trimmed sample**,
not a complete API response. Cookies and infrastructure identifiers were omitted.
Full payloads were downloaded to `/tmp`, not retained in this worktree.

`inspect_catalogue.py` performs eight offline shape checks and regenerates the
evidence file from those temporary payloads. Its docstring has the command. The
first run intentionally exposed an incorrect nonnegative-price assumption: seven
router models have `-1` prices. The final check accepts finite decimal values and
records negative-price model IDs separately. This is empirical evidence, not a
documented guarantee about sentinel semantics.

`mock-credits-and-spend.json` is entirely invented sketch data, labelled mock. It
shows two endpoint rows on one day, a missing day, and separate BYOK costs so a
future sketch can communicate scope and missing data. It proves no private API behavior.

See [the research report](../openrouter-widget-research.md) for limitations and sources.
