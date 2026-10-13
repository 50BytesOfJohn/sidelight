"""Offline inspection of three explicitly supplied public catalogue responses.

No network, credentials, Keychain, or app access. Creates a compact evidence file;
the full downloaded bodies stay in temporary storage. Run from the repo root:
python3 docs/research/openrouter-poc/inspect_catalogue.py \
  /tmp/openrouter-models.json /tmp/openrouter-all.json /tmp/openrouter-page.json \
  /tmp/openrouter-models-headers.txt
"""

import collections
import datetime
import hashlib
import json
import pathlib
import sys
from decimal import Decimal


def inspect(paths):
    snapshots = []
    bodies = []
    for path, url in zip(paths[:3], [
        "https://openrouter.ai/api/v1/models",
        "https://openrouter.ai/api/v1/models?output_modalities=all",
        "https://openrouter.ai/api/v1/models?output_modalities=all&sort=newest&limit=3",
    ]):
        raw = pathlib.Path(path).read_bytes()
        body = json.loads(raw)
        models = body["data"]
        assert len({model["id"] for model in models}) == len(models)
        assert all(isinstance(model["created"], int) for model in models)
        assert all(Decimal(model["pricing"][field]).is_finite()
                   for model in models for field in ["prompt", "completion"])
        bodies.append(body)
        snapshots.append({
            "url": url,
            "body_bytes": len(raw),
            "body_sha256": hashlib.sha256(raw).hexdigest(),
            "returned_count": len(models),
            "total_count": body["total_count"],
            "links": body["links"],
            "modalities": dict(sorted(collections.Counter(
                model["architecture"]["modality"] for model in models).items())),
        })

    default, all_models, page = [body["data"] for body in bodies]
    assert all("text" in model["architecture"]["output_modalities"] for model in default)
    assert {model["id"] for model in default} <= {model["id"] for model in all_models}
    assert snapshots[1]["returned_count"] == snapshots[1]["total_count"]
    assert snapshots[1]["links"]["next"] is None
    newest = sorted(all_models, key=lambda model: (-model["created"], model["id"]))
    assert [model["id"] for model in page] == [model["id"] for model in newest[:3]]
    assert snapshots[2]["links"]["next"] is not None

    selected = newest[:6] + sorted(default, key=lambda model: -model["created"])[:6]
    selected += [model for model in all_models if model["id"] in {
        "openai/gpt-4.1", "apodex/apodex-1.1-mini:free", "poolside/laguna-s-2.1:free",
        "openrouter/free", "openrouter/auto", "google/gemini-2.5-flash",
    }]
    fields = ["id", "canonical_slug", "name", "created", "context_length", "architecture",
              "pricing", "top_provider", "expiration_date", "supported_parameters", "alias_target"]
    samples = []
    seen = set()
    for model in selected:
        if model["id"] in seen:
            continue
        seen.add(model["id"])
        sample = {field: model[field] for field in fields if field in model}
        sample["created_utc"] = datetime.datetime.fromtimestamp(
            model["created"], datetime.timezone.utc).isoformat()
        samples.append(sample)

    # Allowlist intentionally excludes cookies, request IDs and infrastructure headers.
    allowed = {"date", "content-type", "cf-cache-status", "age", "cache-control", "vary",
               "etag", "last-modified", "retry-after"}
    headers = {}
    for line in pathlib.Path(paths[3]).read_text().splitlines():
        if ":" in line:
            name, value = line.split(":", 1)
            if name.lower() in allowed:
                headers[name.lower()] = value.strip()

    return {
        "evidence": "Empirical public unauthenticated GETs, 2026-10-12. Selected fields only.",
        "default_response_headers_allowlisted": headers,
        "snapshots": snapshots,
        "strict_text_to_text_count": sum(
            set(model["architecture"]["input_modalities"]) == {"text"}
            and set(model["architecture"]["output_modalities"]) == {"text"}
            for model in all_models),
        "free_suffix_count": sum(model["id"].endswith(":free") for model in all_models),
        "zero_prompt_completion_count_not_necessarily_free": sum(
            Decimal(model["pricing"]["prompt"]) == 0
            and Decimal(model["pricing"]["completion"]) == 0 for model in all_models),
        "expiration_date_count": sum(model["expiration_date"] is not None for model in all_models),
        "negative_token_price_models": [model["id"] for model in all_models if any(
            Decimal(model["pricing"][field]) < 0 for field in ["prompt", "completion"])],
        "checks_passed": ["unique IDs", "integer created", "finite decimal token prices",
                          "default contains text output", "default subset of all",
                          "all response complete", "newest first page matches created ordering",
                          "pagination next link present"],
        "selected_models": samples,
    }


if __name__ == "__main__":
    if len(sys.argv) != 5:
        raise SystemExit("Provide default, all, newest page JSON paths and default headers path")
    output = pathlib.Path(__file__).with_name("catalogue-evidence.json")
    output.write_text(json.dumps(inspect(sys.argv[1:]), indent=2) + "\n")
    print(f"Passed 8 offline shape checks; wrote {output}")
