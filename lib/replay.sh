#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${1:?usage: $0 <provenance/manifest.json>}"
[[ -f "$MANIFEST" ]] || { echo "manifest not found: $MANIFEST" >&2; exit 2; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVENANCE_DIR="$(cd "$(dirname "$MANIFEST")" && pwd)"
readarray -t FIELDS < <(python3 - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1]) as file:
    manifest = json.load(file)
build = manifest.get("build") or {}
image = manifest.get("image") or {}
print(build.get("dockerfile", ""))
print(image.get("id", ""))
PY
)
DOCKERFILE="${FIELDS[0]}"
EXPECTED_IMAGE_ID="${FIELDS[1]}"

[[ -n "$DOCKERFILE" ]] || {
  echo "manifest does not contain a captured Dockerfile" >&2
  exit 2
}
[[ "$DOCKERFILE" != /* && "$DOCKERFILE" != *".."* ]] || {
  echo "manifest contains an invalid Dockerfile path: $DOCKERFILE" >&2
  exit 2
}

REPLAY_DIR="$(mktemp -d)"
trap 'rm -rf "$REPLAY_DIR"' EXIT
IMAGE="perf-eval-replay:$(printf '%s' "$EXPECTED_IMAGE_ID" | sha256sum | cut -c1-12)"
REBUILT_IMAGE_ID="$(python3 "$DIR/provenance.py" build \
  --image "$IMAGE" \
  --dockerfile "$PROVENANCE_DIR/$DOCKERFILE")"
if [[ -n "$EXPECTED_IMAGE_ID" && "$REBUILT_IMAGE_ID" != "$EXPECTED_IMAGE_ID" ]]; then
  echo "rebuilt image ID does not match the recorded image ID" >&2
  echo "recorded: $EXPECTED_IMAGE_ID" >&2
  echo "rebuilt:  $REBUILT_IMAGE_ID" >&2
  exit 2
fi
REPLAY_WORKLOAD="$REPLAY_DIR/workload.yaml"
python3 - "$PROVENANCE_DIR/workload.yaml" "$REPLAY_WORKLOAD" "$IMAGE" <<'PY'
import sys
import yaml

with open(sys.argv[1]) as file:
    workload = yaml.safe_load(file)
workload["vllm"].pop("build", None)
workload["vllm"]["image"] = sys.argv[3]
with open(sys.argv[2], "w") as file:
    yaml.safe_dump(workload, file, sort_keys=False)
PY
PERF_EVAL_PROFILES_FILE="$DIR/gpu_profiles.yaml" "$DIR/run.sh" "$REPLAY_WORKLOAD"
