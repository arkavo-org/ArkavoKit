#!/usr/bin/env bash
# Runs the C2PA Conformance Program asset rubrics on a signed asset and exits non-zero on
# any failure (the program's own evaluator exits 0 even when rules fail).
#
#   scripts/c2pa-conformance/run.sh <signed asset> [--spec 2.2|2.4] [--trust-anchors CA.pem]
#                                   [--tsa-anchors C2PA-TSA-TRUST-LIST.pem] [--waive RULE_ID]...
#
# The first run fetches conformance-public at a pinned commit and creates a Python venv with
# the evaluator's requirements, both under .build/c2pa-conformance. Needs git, python3 and
# c2patool. `--tsa-anchors default` uses the pinned C2PA TSA trust list.
set -euo pipefail

CONFORMANCE_COMMIT=da71a7231fd6c86d308771dbb5557fabc920997a
here="$(cd "$(dirname "$0")" && pwd)"
cache="${C2PA_CONFORMANCE_CACHE:-$here/../../.build/c2pa-conformance}"
repo="$cache/conformance-public"
venv="$cache/venv-${CONFORMANCE_COMMIT:0:12}"  # rebuilt when the pinned commit changes

command -v c2patool >/dev/null || { echo "error: c2patool not found (brew install c2patool)" >&2; exit 2; }

if [ "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" != "$CONFORMANCE_COMMIT" ]; then
    rm -rf "$repo"
    mkdir -p "$cache"
    git clone --quiet --filter=blob:none https://github.com/c2pa-org/conformance-public.git "$repo"
    git -C "$repo" checkout --quiet "$CONFORMANCE_COMMIT"
fi
if [ ! -x "$venv/bin/python" ]; then
    python3 -m venv "$venv"
    "$venv/bin/pip" install --quiet -r "$repo/asset-rubrics/requirements.txt"
fi

args=()
for arg in "$@"; do
    if [ "$arg" = default ] && [ "${prev:-}" = --tsa-anchors ]; then
        arg="$repo/trust-list/C2PA-TSA-TRUST-LIST.pem"
    fi
    args+=("$arg")
    prev="$arg"
done

exec "$venv/bin/python" "$here/run_conformance.py" --conformance-public "$repo" ${args[@]+"${args[@]}"}
