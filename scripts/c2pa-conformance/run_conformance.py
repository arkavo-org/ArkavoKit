#!/usr/bin/env python3
"""Run the C2PA Conformance Program asset rubrics against a signed asset and fail properly.

The program's evaluator (conformance-public/asset-rubrics/c2pa_conformance_rubric_evaluator.py)
exits 0 even when rules fail. This runner:

  1. produces crJSON with `c2patool <asset> --crjson` (optionally with trust anchors),
  2. runs the program rubric for the chosen spec and the integrity rubric,
  3. prints a pass/fail/warn table per rubric with each failing rule and its report text,
  4. on a MOV/MP4/M4A, runs the container checks in container_checks.py (T14 placement,
     T6 media tamper, T8 manifest removal, and T9 re-sign with --c2pa-sign) on copies,
  5. saves every raw output under --out,
  6. exits 1 on any failed rule, evaluator error, malformed or empty output, rule that
     did not execute, or failed container check; 2 on usage or tool errors.

Trust: c2patool 0.27.x (c2pa-rs 0.90) checks both the signing credential and the timestamp
against one anchor set, so --trust-anchors and --tsa-anchors are concatenated and passed with
`trust --trust_anchors`. Without either, signer and timestamp trust are reported untrusted.

A documented exception (e.g. the signer-trust failure before a C2PA certificate is issued)
must be waived explicitly with --waive RULE_ID; waived failures are listed, never hidden.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

import container_checks

import_error = None
try:
    import yaml  # noqa: F401  (only needed to count rubric statements)
except Exception as exc:  # pragma: no cover
    import_error = exc



def fail_usage(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(2)


def expected_traits(rubric_path):
    """Display names of the rubric statements the evaluator will run (those with an expression)."""
    import yaml

    with open(rubric_path) as f:
        docs = list(yaml.safe_load_all(f))
    statements = []
    for doc in docs[1:]:
        if isinstance(doc, list):
            statements.extend(doc)
        elif isinstance(doc, dict) and "block" not in doc:
            statements.append(doc)
    traits = []
    for stmt in statements:
        if not isinstance(stmt, dict) or not stmt.get("expression"):
            continue
        stmt_id = stmt.get("id") or "unnamed_trait"
        name = stmt_id
        if stmt_id == "c2pa:signal_compliance":
            true_text = stmt.get("reportText", {}).get("true", {}).get("en", "")
            if true_text:
                name = true_text[9:] if true_text.startswith("Contains ") else true_text
        traits.append(name.split(":", 1)[1] if ":" in name else name)
    return traits


def make_crjson(asset, anchors, out_dir):
    cmd = ["c2patool", str(asset), "--crjson"]
    if anchors:
        cmd += ["trust", "--trust_anchors", str(anchors)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    (out_dir / "c2patool.stderr.txt").write_text(proc.stderr)
    raw_path = out_dir / "asset.crjson.json"
    raw_path.write_text(proc.stdout)
    if proc.returncode != 0:
        fail_usage(f"c2patool exited {proc.returncode}: {proc.stderr.strip()[:500]}")
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        fail_usage(f"c2patool output is not JSON ({exc}); see {raw_path}")
    if not data.get("manifests"):
        fail_usage(f"no manifests in crJSON; see {raw_path}")
    return raw_path, data


def run_rubric(python, evaluator, rubric, crjson_path, spec, out_dir, label):
    proc = subprocess.run(
        [str(python), "-I", str(evaluator), str(rubric), str(crjson_path), "--spec-version", spec],
        capture_output=True,
        text=True,
    )
    (out_dir / f"{label}.stdout.json").write_text(proc.stdout)
    (out_dir / f"{label}.stderr.txt").write_text(proc.stderr)
    problems = []
    if proc.returncode != 0:
        problems.append(f"evaluator exited {proc.returncode}")
    for line in proc.stderr.splitlines():
        if line.startswith(("Warning:", "Error")) or "Traceback" in line:
            problems.append(f"evaluator: {line.strip()}")
    try:
        output = json.loads(proc.stdout) if proc.stdout.strip() else None
    except json.JSONDecodeError as exc:
        output = None
        problems.append(f"evaluator output is not JSON: {exc}")
    if not isinstance(output, dict) or not all(k in output for k in ("true", "false", "warning")):
        problems.append("evaluator produced no result object")
        output = None
    return output, problems


def summarize(label, rubric, output, problems, expected, waive):
    passed, failed, warned, waived = [], [], [], []
    errors = list(problems)
    if output is not None:
        for outcome, bucket in (("true", passed), ("false", failed), ("warning", warned)):
            for category, items in output[outcome].items():
                for item in items:
                    rule = f"{category}:{item.get('trait')}"
                    text = (item.get("reportText") or "").strip().replace("\n", " ")
                    if outcome == "false" and text.startswith("Error:"):
                        errors.append(f"{rule} raised {text}")
                        continue
                    if outcome == "false" and rule in waive:
                        waived.append((rule, text))
                        continue
                    bucket.append((rule, text))
        reported = {r.split(":", 1)[1] for r, _ in passed + failed + warned + waived}
        reported |= {e.split(" raised ", 1)[0].split(":", 1)[1] for e in errors if " raised " in e}
        missing = [t for t in expected if t not in reported]
        if missing:
            errors.append(f"{len(missing)} rule(s) did not execute: {', '.join(missing)}")
        if not passed and not failed and not warned:
            errors.append("no rule results")

    name = output.get("rubricName", "?") if output else "?"
    print(f"\n== {label}: {rubric.name} ({name})")
    print(f"   pass {len(passed)}  fail {len(failed)}  warn {len(warned)}"
          + (f"  waived {len(waived)}" if waived else "")
          + (f"  errors {len(errors)}" if errors else ""))
    for rule, text in failed:
        print(f"   FAIL  {rule}: {text}")
    for rule, text in waived:
        print(f"   WAIVED {rule}: {text}")
    for rule, text in warned:
        print(f"   WARN  {rule}: {text}")
    for error in errors:
        print(f"   ERROR {error}")
    return {"rubric": rubric.name, "pass": len(passed), "fail": len(failed), "warn": len(warned),
            "waived": [r for r, _ in waived], "failed": [r for r, _ in failed], "errors": errors}


def validation_codes(data):
    manifest = data["manifests"][0]
    results = manifest.get("validationResults") or {}
    return {k: [x.get("code") for x in results.get(k, [])] for k in ("success", "informational", "failure")}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("asset", type=Path, help="signed asset (MOV/MP4/M4A/...) or an existing crJSON file (*.json)")
    parser.add_argument("--spec", choices=["2.2", "2.4"], default="2.2", help="claimed C2PA spec version (default 2.2)")
    parser.add_argument("--trust-anchors", type=Path, help="PEM of signer trust anchors (e.g. the Arkavo C2PA CA)")
    parser.add_argument("--tsa-anchors", type=Path, help="PEM of TSA trust anchors (e.g. C2PA-TSA-TRUST-LIST.pem)")
    parser.add_argument("--waive", action="append", default=[], metavar="RULE_ID",
                        help="treat this failing rule as a documented exception, e.g. validation:trusted_success")
    parser.add_argument("--out", type=Path, help="directory for raw outputs (default: <asset>.conformance/)")
    parser.add_argument("--conformance-public", type=Path, required=True,
                        help="checkout of github.com/c2pa-org/conformance-public (run.sh pins and fetches it)")
    parser.add_argument("--python", type=Path, default=Path(sys.executable),
                        help="python with the evaluator's requirements (default: this one)")
    parser.add_argument("--c2pa-sign", type=Path, metavar="PATH",
                        help="c2pa-sign binary: also check it refuses the signed file (T9)")
    parser.add_argument("--no-container-checks", action="store_true",
                        help="skip T14/T6/T8/T9 on a MOV/MP4/M4A")
    args = parser.parse_args()

    if import_error is not None:
        fail_usage(f"PyYAML is required to run this script ({import_error}); use the rubric venv python")
    if not args.asset.exists():
        fail_usage(f"no such asset: {args.asset}")
    rubrics_dir = args.conformance_public / "asset-rubrics"
    evaluator = rubrics_dir / "c2pa_conformance_rubric_evaluator.py"
    program = rubrics_dir / f"asset-rubric-conformance0.2-spec{args.spec}.yml"
    integrity = rubrics_dir / "asset-rubric-integrity.yml"
    for path in (evaluator, program, integrity, args.python):
        if not path.exists():
            fail_usage(f"missing {path}")

    containers = (not args.no_container_checks and args.asset.suffix.lower() in container_checks.BMFF_SUFFIXES)
    if args.c2pa_sign and not containers:
        fail_usage("--c2pa-sign runs with the container checks, on a MOV/MP4/M4A")
    if containers:
        missing = container_checks.missing_tools(args.c2pa_sign)
        if missing:
            fail_usage(f"the container checks need {', '.join(missing)} (or pass --no-container-checks)")

    out_dir = args.out or args.asset.with_name(args.asset.name + ".conformance")
    out_dir.mkdir(parents=True, exist_ok=True)

    anchors = None
    if args.asset.suffix == ".json":
        if args.trust_anchors or args.tsa_anchors:
            fail_usage("trust anchors apply when producing crJSON; pass the asset, not a crJSON file")
        crjson_path = args.asset
        try:
            data = json.loads(crjson_path.read_text())
        except json.JSONDecodeError as exc:
            fail_usage(f"{crjson_path} is not JSON ({exc})")
        if not isinstance(data, dict) or not data.get("manifests"):
            fail_usage(f"no manifests in {crjson_path}")
    else:
        pems = [p for p in (args.trust_anchors, args.tsa_anchors) if p]
        if pems:
            anchors = out_dir / "trust-anchors.pem"
            anchors.write_text("".join(Path(p).read_text().rstrip("\n") + "\n" for p in pems))
        crjson_path, data = make_crjson(args.asset, anchors, out_dir)

    codes = validation_codes(data)
    generator = data.get("jsonGenerator", {})
    print(f"asset:      {args.asset}")
    print(f"crJSON:     {crjson_path} ({generator.get('name')} {generator.get('version')})")
    print(f"spec:       {args.spec}   trust: signer={'yes' if args.trust_anchors else 'no'} "
          f"tsa={'yes' if args.tsa_anchors else 'no'}")
    print(f"validation: failure={codes['failure']} informational={codes['informational']}")

    summaries = []
    for label, rubric in (("program", program), ("integrity", integrity)):
        output, problems = run_rubric(args.python, evaluator, rubric, crjson_path, args.spec, out_dir, label)
        summaries.append(summarize(label, rubric, output, problems, expected_traits(rubric), set(args.waive)))

    unused = set(args.waive) - {r for s in summaries for r in s["waived"]}
    if unused:
        print(f"\nnote: --waive given for rules that did not fail: {', '.join(sorted(unused))}")

    # The integrity rubric doesn't catch an informational timeStamp.untrusted, so timestamp
    # trust is checked separately whenever TSA anchors are supplied (self-test plan T2).
    timestamp_ok = True
    if args.tsa_anchors:
        timestamp_ok = "timeStamp.trusted" in codes["success"]
        print(f"\n== timestamp trust: {'trusted' if timestamp_ok else 'NOT trusted'}"
              f" (success has timeStamp.trusted: {timestamp_ok}; informational: {codes['informational']})")

    container_result = None
    if containers:
        container_result = container_checks.check(args.asset, anchors, out_dir / "containers", args.c2pa_sign)
        container_checks.print_result(container_result)

    (out_dir / "summary.json").write_text(json.dumps(
        {"asset": str(args.asset), "spec": args.spec, "validation": codes, "timestamp_trusted": timestamp_ok,
         "rubrics": summaries, "containers": container_result}, indent=2))
    ok = (timestamp_ok and all(not s["fail"] and not s["errors"] for s in summaries)
          and (container_result is None or container_result["pass"]))
    print(f"\nresult: {'PASS' if ok else 'FAIL'}   (raw outputs in {out_dir})")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
