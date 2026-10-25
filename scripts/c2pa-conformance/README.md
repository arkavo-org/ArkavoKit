# C2PA conformance checks

`run.sh` runs the [C2PA Conformance Program](https://github.com/c2pa-org/conformance-public)'s asset rubrics on a signed file. It exits non-zero on any failure. The program's own evaluator exits 0 even when rules fail, so its exit code can't gate anything.

```bash
scripts/c2pa-conformance/run.sh signed.mov \
    --spec 2.2 \
    --trust-anchors arkavo_c2pa_ca.pem \
    --tsa-anchors default
```

- **Rubrics:** it produces crJSON with `c2patool --crjson`, then runs two rubrics: the program rubric for `--spec`, `asset-rubric-conformance0.2-spec<spec>.yml`, and `asset-rubric-integrity.yml`.
- **Timestamp trust:** with `--tsa-anchors`, it also requires `timeStamp.trusted`. The integrity rubric doesn't catch an informational `timeStamp.untrusted`. `default` means the C2PA TSA trust list at the pinned commit.
- **Trust anchors:** c2patool 0.27 checks the signer and the timestamp against one anchor set, so the two PEM files are joined.
- **Waivers:** `--waive RULE_ID` turns a documented exception into a listed waiver instead of a failure. An example is `validation:trusted_success`, while the signer still chains to a private CA. Waived failures are always printed.
- **Output:** raw outputs and `summary.json` go to `<asset>.conformance/`, or to `--out`. You can also pass a crJSON file instead of an asset.
- **Exit codes:** `1` for a failed rule, an evaluator error, a rule that didn't run, or an untrusted timestamp. `2` for a usage or tool error.

## Setup

You need `git`, `python3` and `c2patool`. On the first run, the script fetches conformance-public at a pinned commit (`CONFORMANCE_COMMIT` in `run.sh`) and creates a venv with the evaluator's requirements. Both go under `.build/c2pa-conformance`. Bump the commit deliberately: the rubrics change between program versions.

## Signing a sample

Sign with `c2pa-sign` against the server under test, then check the result:

```bash
swift run c2pa-sign recording.mov signed.mov --server https://platform.arkavo.net --token "$ARKAVO_TOKEN"
scripts/c2pa-conformance/run.sh signed.mov --trust-anchors arkavo_c2pa_ca.pem --tsa-anchors default
```

For a passing run, the server must sign with a timestamp authority on the C2PA TSA trust list (arks `C2PA_TSA_URL`).
