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
- **Container checks:** on a MOV, MP4 or M4A, it then runs the self-test plan's container checks from `container_checks.py`. Pass `--no-container-checks` to skip them.
- **Output:** raw outputs and `summary.json` go to `<asset>.conformance/`, or to `--out`. You can also pass a crJSON file instead of an asset; the container checks need the asset, so they don't run then.
- **Exit codes:** `1` for a failed rule, an evaluator error, a rule that didn't run, an untrusted timestamp or a failed container check. `2` for a usage or tool error.

## Container checks

| Test | What it checks |
|---|---|
| T14, placement | The manifest box is the box right after `ftyp`, before `moov` and every `mdat`, with purpose `manifest`. Every sample, from `stco`/`co64`, `stsc` and `stsz`, lies inside an `mdat`. ffmpeg decodes the file cleanly, and ffprobe shows packet DTS strictly increasing in each stream. |
| T6, media tamper | A copy with one byte flipped in the middle of the first `mdat` reports `assertion.dataHash.mismatch`. |
| T8, manifest removal | A copy whose manifest box is renamed to a same-size `free` box, so no offset moves, has no claim, decodes cleanly and has the same streams as the signed file. |
| T9, re-sign | With `--c2pa-sign PATH`: `c2pa-sign` refuses the signed file because it already has a manifest, before any request (the server given is one that refuses connections), and writes no output. |
| T10, embedding | With `--unsigned PATH`, the file before signing: the signed file has the same streams (ffprobe) and every packet's payload (`ffmpeg -f framemd5 -c copy`). |
| T7, transplant | With `--transplant-from PATH`, another signed file: this file with that one's manifest box fails validation. A box of the same size (so the same layout) must fail on the hard binding, `assertion.dataHash.mismatch`. |

- **Copies only:** the tampered copies go under `<out>/containers/`. The input is only read, and its SHA-256 is checked afterwards.
- **Standalone:** `container_checks.py --anchors CA.pem --out DIR [--c2pa-sign PATH] asset...` runs the same checks without the rubrics.
- **Tests:** the checker's own tests use hand-built files: `python3 -m unittest discover -s scripts/c2pa-conformance/tests`.
- **Fixtures:** `make_fixtures.sh OUT_DIR` generates the unsigned inputs for T7, T10 and S5: two same-layout clips, and a 4.3 GB file whose chunk offsets sit just under 2³², so signing must turn `stco` into `co64`. Sign them with `c2pa-sign`, then run `run.sh` on the signed files. The media stays out of the repo.
- **Still manual:** comparing sample counts through AVAssetReader. T5 has no validator on an engine other than c2pa-rs yet (#36).

## Setup

You need `git`, `python3` and `c2patool`, plus `ffmpeg` and `ffprobe` for the container checks. On the first run, the script fetches conformance-public at a pinned commit (`CONFORMANCE_COMMIT` in `run.sh`) and creates a venv with the evaluator's requirements. Both go under `.build/c2pa-conformance`. Bump the commit deliberately: the rubrics change between program versions.

## Signing a sample

Sign with `c2pa-sign` against the server under test, then check the result:

```bash
swift run c2pa-sign recording.mov signed.mov --server https://platform.arkavo.net --token "$ARKAVO_TOKEN"
scripts/c2pa-conformance/run.sh signed.mov --trust-anchors arkavo_c2pa_ca.pem --tsa-anchors default
```

For a passing run, the server must sign with a timestamp authority on the C2PA TSA trust list (arks `C2PA_TSA_URL`).
