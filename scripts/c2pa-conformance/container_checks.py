#!/usr/bin/env python3
"""Self-test plan container checks on a signed ISO BMFF file (MOV/MP4/M4A).

  T14  placement: the C2PA manifest box comes right after ftyp, before moov and every
       mdat, and every sample (from stco/co64, stsc, stsz) lies inside an mdat; the signed
       file decodes cleanly with strictly increasing packet DTS
  T6   media tamper: a copy with one mdat byte flipped reports assertion.dataHash.mismatch
  T8   manifest removal: a copy with the manifest box turned into a same-size free box has
       no claim, decodes cleanly and has the same streams as the signed file
  T9   re-sign (only with --c2pa-sign): c2pa-sign refuses the signed file before any
       request, writes nothing and leaves the input unchanged
  T10  embedding (only with --unsigned): the signed file has the unsigned input's streams and
       every packet's payload, by ffprobe and `ffmpeg -f framemd5 -c copy`
  T7   transplant (only with --transplant-from): the signed file with another signed file's
       manifest box in place of its own fails validation. A box of the same size, so the same
       layout, must fail on the hard binding (assertion.dataHash.mismatch)

Tampered copies go under --out; the input is only read, and its SHA-256 is checked
afterwards. Needs c2patool, ffmpeg and ffprobe. Exits 1 if any check fails, 2 on a usage
or tool error. run_conformance.py runs these after the rubrics.

  container_checks.py --anchors anchors.pem --out DIR [--c2pa-sign PATH] asset...
  container_checks.py --anchors anchors.pem --out DIR [--unsigned PATH] [--transplant-from PATH] asset
"""
import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import sys
from pathlib import Path

C2PA_UUID = bytes.fromhex("d8fec3d61b0e483c92975828877ec481")
BMFF_SUFFIXES = {".mov", ".mp4", ".m4a", ".m4v"}
REQUIRED_TOOLS = ("c2patool", "ffmpeg", "ffprobe")
# A server that refuses connections: T9 must fail before it would matter
UNREACHABLE_SERVER = "https://127.0.0.1:1"


# MARK: - Boxes

def parse_boxes(data, start, end):
    out, off = [], start
    while off < end:
        if off + 8 > end:
            raise ValueError(f"truncated box header at {off}")
        size, kind = struct.unpack(">I4s", data[off:off + 8])
        hdr = 8
        if size == 1:
            if off + 16 > end:
                raise ValueError(f"truncated box header at {off}")
            size, hdr = struct.unpack(">Q", data[off + 8:off + 16])[0], 16
        elif size == 0:
            size = end - off
        if size < hdr or off + size > end:
            raise ValueError(f"box '{kind.decode('latin1')}' at {off} has bad size {size}")
        out.append({"type": kind.decode("latin1"), "offset": off, "size": size, "hdr": hdr})
        off += size
    return out


def children(data, box):
    return parse_boxes(data, box["offset"] + box["hdr"], box["offset"] + box["size"])


def find(data, box, path):
    """Descendants of `box` along `path`, e.g. ['mdia', 'minf', 'stbl']"""
    level = [box]
    for name in path:
        level = [c for b in level for c in children(data, b) if c["type"] == name]
    return level


def full_box_payload(data, box):
    return data[box["offset"] + box["hdr"] + 4:box["offset"] + box["size"]]


def is_manifest_box(data, box):
    start = box["offset"] + box["hdr"]
    return box["type"] == "uuid" and data[start:start + 16] == C2PA_UUID


def manifest_boxes(top, data):
    return [b for b in top if is_manifest_box(data, b)]


def mdat_payloads(top):
    return [(b["offset"] + b["hdr"], b["offset"] + b["size"]) for b in top if b["type"] == "mdat"]


def sample_ranges(data, stbl):
    """(offset, size) of every sample in a track, from stco/co64, stsc and stsz"""
    boxes = {c["type"]: c for c in children(data, stbl)}
    if "stco" in boxes:
        kind, width, fmt = "stco", 4, "I"
    elif "co64" in boxes:
        kind, width, fmt = "co64", 8, "Q"
    else:
        raise ValueError("track has neither stco nor co64")
    for required in ("stsc", "stsz"):
        if required not in boxes:
            raise ValueError(f"track has no {required}")
    p = full_box_payload(data, boxes[kind])
    n = struct.unpack(">I", p[:4])[0]
    chunks = struct.unpack(f">{n}{fmt}", p[4:4 + width * n])
    p = full_box_payload(data, boxes["stsc"])
    n = struct.unpack(">I", p[:4])[0]
    stsc = [struct.unpack(">III", p[4 + 12 * i:16 + 12 * i]) for i in range(n)]
    p = full_box_payload(data, boxes["stsz"])
    uniform, count = struct.unpack(">II", p[:8])
    sizes = [uniform] * count if uniform else list(struct.unpack(f">{count}I", p[8:8 + 4 * count]))
    ranges, s = [], 0
    for index, chunk_offset in enumerate(chunks, start=1):
        per_chunk = [e for e in stsc if e[0] <= index][-1][1]
        offset = chunk_offset
        for _ in range(per_chunk):
            if s >= len(sizes):
                break
            ranges.append((offset, sizes[s]))
            offset += sizes[s]
            s += 1
    if s != len(sizes):
        raise ValueError(f"chunk table describes {s} samples, stsz has {len(sizes)}")
    return kind, ranges


# MARK: - T14

def placement(data):
    """T14 on the file's bytes: (report, problems). A malformed file is one problem."""
    try:
        return _placement(data)
    except (ValueError, struct.error, IndexError) as exc:
        return {"top_level": None, "manifest_box": None, "tracks": []}, [f"malformed: {exc}"]


def _placement(data):
    top = parse_boxes(data, 0, len(data))
    problems = []
    if not top or top[0]["type"] != "ftyp":
        problems.append("first box is not ftyp")
    manifests = [i for i, b in enumerate(top) if is_manifest_box(data, b)]
    if manifests != [1]:
        problems.append(f"C2PA uuid boxes at top-level positions {manifests}, expected exactly [1]")
    manifest = top[manifests[0]] if manifests else None
    if manifest:
        body = data[manifest["offset"] + manifest["hdr"] + 16 + 4:manifest["offset"] + manifest["size"]]
        purpose = body[:body.index(b"\0")].decode() if b"\0" in body else None
        if purpose != "manifest":
            problems.append(f"manifest box purpose is {purpose!r}")
        before = [b["type"] for b in top if b["type"] in ("moov", "mdat") and b["offset"] < manifest["offset"]]
        if before:
            problems.append(f"{before} before the manifest box")
    moovs = [b for b in top if b["type"] == "moov"]
    mdats = mdat_payloads(top)
    if not moovs:
        problems.append("no moov box")
    if not mdats:
        problems.append("no mdat box")
    tracks = []
    for trak in find(data, moovs[0], ["trak"]) if moovs else []:
        handler = full_box_payload(data, find(data, trak, ["mdia", "hdlr"])[0])[4:8].decode("latin1")
        kind, ranges = sample_ranges(data, find(data, trak, ["mdia", "minf", "stbl"])[0])
        outside = [r for r in ranges if not any(lo <= r[0] and r[0] + r[1] <= hi for lo, hi in mdats)]
        if outside:
            problems.append(f"{handler} track: {len(outside)} of {len(ranges)} samples outside mdat, first {outside[0]}")
        tracks.append({"handler": handler, "offsets": kind, "samples": len(ranges), "outside_mdat": len(outside)})
    report = {
        "top_level": [(b["type"], b["offset"], b["size"]) for b in top],
        "manifest_box": (manifest["offset"], manifest["size"]) if manifest else None,
        "tracks": tracks,
    }
    return report, problems


# MARK: - Tampered copies

def tampered(data):
    """T6: the file with one byte flipped in the middle of the first mdat payload, and its offset"""
    lo, hi = mdat_payloads(parse_boxes(data, 0, len(data)))[0]
    offset = (lo + hi) // 2
    copy = bytearray(data)
    copy[offset] ^= 0x01
    return bytes(copy), offset


def transplanted(data, donor):
    """T7: `data` with its manifest box replaced by `donor`'s, and whether the two boxes are the
    same size, so that no media offset moves"""
    own = manifest_boxes(parse_boxes(data, 0, len(data)), data)[0]
    theirs = manifest_boxes(parse_boxes(donor, 0, len(donor)), donor)[0]
    box = donor[theirs["offset"]:theirs["offset"] + theirs["size"]]
    copy = data[:own["offset"]] + box + data[own["offset"] + own["size"]:]
    return bytes(copy), theirs["size"] == own["size"]


def manifest_removed(data):
    """T8: the file with its manifest box renamed to a same-size free box, so no media offset moves"""
    manifest = manifest_boxes(parse_boxes(data, 0, len(data)), data)[0]
    copy = bytearray(data)
    copy[manifest["offset"] + 4:manifest["offset"] + 8] = b"free"
    return bytes(copy)


# MARK: - Tools

def c2pa_codes(path, anchors, report_path):
    """c2patool's crJSON validation codes for `path`, or None when it reports no manifest"""
    command = ["c2patool", str(path), "--crjson"]
    if anchors:
        command += ["trust", "--trust_anchors", str(anchors)]
    proc = subprocess.run(command, capture_output=True, text=True)
    report_path.write_text(proc.stdout + ("\n--- stderr ---\n" + proc.stderr if proc.stderr else ""))
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None, proc.stderr.strip()
    results = (data.get("manifests") or [{}])[0].get("validationResults") or {}
    codes = {k: [x.get("code") for x in results.get(k, [])] for k in ("success", "informational", "failure")}
    return codes, proc.stderr.strip()


def decode_errors(path):
    """ffmpeg decodes every stream and ffprobe checks packet DTS strictly increases per stream.
    The null muxer's "non monotonically increasing dts" line is dropped: it comes from rounding
    variable frame timing onto the output rate, and the DTS check covers the file itself."""
    proc = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-f", "null", "-"],
                          capture_output=True, text=True)
    errors = [line for line in proc.stderr.splitlines()
              if "non monotonically increasing dts to muxer" not in line]
    if proc.returncode:
        errors.append(f"ffmpeg exited {proc.returncode}")
    probe = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "packet=stream_index,dts",
                            "-of", "csv=p=0", str(path)], capture_output=True, text=True)
    if probe.returncode:
        errors.append(f"ffprobe exited {probe.returncode}: {probe.stderr.strip()[:200]}")
    return errors + dts_problems(probe.stdout.splitlines())


def dts_problems(lines):
    """Packets whose DTS doesn't strictly increase in their stream, from ffprobe's
    `stream_index,dts` lines. Lines without both fields, and N/A, carry no DTS to compare."""
    problems, last = [], {}
    for line in lines:
        fields = line.split(",")
        if len(fields) < 2 or not fields[1].lstrip("-").isdigit():
            continue
        stream, dts = fields[0], int(fields[1])
        if stream in last and dts <= last[stream]:
            problems.append(f"stream {stream}: packet dts {dts} after {last[stream]}")
        last[stream] = dts
    return problems


def framemd5(path):
    """ffmpeg's per-packet checksums of every stream, copied without decoding"""
    proc = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-map", "0", "-c", "copy",
                           "-f", "framemd5", "-"], capture_output=True, text=True)
    return proc.stdout.splitlines(), proc.stderr.strip() if proc.returncode else ""


def framemd5_differences(signed, unsigned):
    """How two framemd5 listings differ: the first differing packet and any count mismatch.
    Comment lines (stream headers) are skipped."""
    a = [line for line in signed if line.strip() and not line.startswith("#")]
    b = [line for line in unsigned if line.strip() and not line.startswith("#")]
    problems = []
    for index, (x, y) in enumerate(zip(a, b), start=1):
        if x != y:
            problems.append(f"packet {index} differs: signed {x!r}, unsigned {y!r}")
            break
    if len(a) != len(b):
        problems.append(f"signed has {len(a)} packets, unsigned {len(b)}")
    return problems


def streams(path):
    """ffprobe's stream list for `path`, or None and the reason when ffprobe can't read it"""
    proc = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(path)],
                          capture_output=True, text=True)
    if proc.returncode:
        return None, f"ffprobe exited {proc.returncode}: {proc.stderr.strip()[:200]}"
    try:
        return json.loads(proc.stdout)["streams"], ""
    except (json.JSONDecodeError, KeyError) as exc:
        return None, f"ffprobe output unreadable: {exc}"


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def missing_tools(c2pa_sign=None):
    missing = [t for t in REQUIRED_TOOLS if shutil.which(t) is None]
    if c2pa_sign and not Path(c2pa_sign).is_file():
        missing.append(str(c2pa_sign))
    return missing


# MARK: - Checks

def check(asset, anchors, out_dir, c2pa_sign=None, unsigned=None, donor=None):
    """Runs T14, T6, T8 and, when given what they need, T9 (`c2pa_sign`), T10 (`unsigned`, the
    file before signing) and T7 (`donor`, another signed file) on `asset`. Returns a JSON-able
    result."""
    out_dir.mkdir(parents=True, exist_ok=True)
    before = sha256(asset)
    data = asset.read_bytes()
    result = {"asset": str(asset), "sha256": before, "size": len(data)}

    report, problems = placement(data)
    problems += decode_errors(asset)
    result["T14"] = {**report, "problems": problems, "pass": not problems}
    if report["top_level"] is None or not manifest_boxes(parse_boxes(data, 0, len(data)), data):
        result["pass"] = False
        result["note"] = "T6/T8/T9 need a parseable file with a manifest box"
        return result

    copy, offset = tampered(data)
    t6_path = out_dir / f"t6-tampered{asset.suffix}"
    t6_path.write_bytes(copy)
    codes, err = c2pa_codes(t6_path, anchors, out_dir / "t6-c2patool.txt")
    result["T6"] = {"flipped_offset": offset, "codes": codes, "stderr": err[:300],
                    "pass": codes is not None and "assertion.dataHash.mismatch" in codes["failure"]}

    t8_path = out_dir / f"t8-manifest-removed{asset.suffix}"
    t8_path.write_bytes(manifest_removed(data))
    codes, err = c2pa_codes(t8_path, anchors, out_dir / "t8-c2patool.txt")
    no_claim = codes is None and "no claim found" in err.lower()
    errors = decode_errors(t8_path)
    signed_streams, signed_error = streams(asset)
    removed_streams, removed_error = streams(t8_path)
    errors += [e for e in (signed_error, removed_error) if e]
    same_streams = signed_streams is not None and signed_streams == removed_streams
    result["T8"] = {"c2patool_stderr": err[:300], "decode_errors": errors[:5], "streams_match_signed": same_streams,
                    "pass": no_claim and not errors and same_streams}

    if c2pa_sign:
        t9_out = out_dir / f"t9-resigned{asset.suffix}"
        t9_out.unlink(missing_ok=True)
        proc = subprocess.run([str(c2pa_sign), str(asset), str(t9_out), "--server", UNREACHABLE_SERVER],
                              capture_output=True, text=True)
        output = proc.stdout + proc.stderr
        refused = "already contains a C2PA manifest" in output
        result["T9"] = {"exit": proc.returncode, "refused_for_manifest": refused, "wrote_output": t9_out.exists(),
                        "pass": proc.returncode != 0 and refused and not t9_out.exists()}

    if unsigned:
        signed_streams, signed_error = streams(asset)
        unsigned_streams, unsigned_error = streams(unsigned)
        signed_packets, signed_packet_error = framemd5(asset)
        unsigned_packets, unsigned_packet_error = framemd5(unsigned)
        errors = [e for e in (signed_error, unsigned_error, signed_packet_error, unsigned_packet_error) if e]
        differences = framemd5_differences(signed_packets, unsigned_packets)
        same_streams = signed_streams is not None and signed_streams == unsigned_streams
        result["T10"] = {"unsigned": str(unsigned), "streams_match": same_streams,
                         "packets": len([line for line in signed_packets if line and not line.startswith("#")]),
                         "payload_differences": differences, "errors": errors[:5],
                         "pass": same_streams and not differences and not errors}

    if donor:
        copy, aligned = transplanted(data, donor.read_bytes())
        t7_path = out_dir / f"t7-transplanted{asset.suffix}"
        t7_path.write_bytes(copy)
        codes, err = c2pa_codes(t7_path, anchors, out_dir / "t7-c2patool.txt")
        if aligned:
            refused = codes is not None and "assertion.dataHash.mismatch" in codes["failure"]
        else:
            refused = codes is None or bool(codes["failure"])
        result["T7"] = {"donor": str(donor), "aligned": aligned, "codes": codes, "stderr": err[:300], "pass": refused}

    result["input_unchanged"] = sha256(asset) == before
    result["pass"] = result["input_unchanged"] and all(
        result[t]["pass"] for t in ("T14", "T6", "T8", "T9", "T10", "T7") if t in result)
    return result


def print_result(result):
    print(f"\n== container checks: {Path(result['asset']).name} ({result['size']} bytes, sha256 {result['sha256'][:16]}…)")
    t14 = result["T14"]
    order = [t for t, _, _ in t14["top_level"]] if t14["top_level"] else None
    print(f"T14 placement:      {'PASS' if t14['pass'] else 'FAIL'}  boxes={order}  tracks={t14['tracks']}")
    for p in t14["problems"]:
        print(f"    - {p}")
    if "note" in result:
        print(f"    - {result['note']}")
        return
    t6 = result["T6"]
    print(f"T6 media tamper:    {'PASS' if t6['pass'] else 'FAIL'}  byte {t6['flipped_offset']} flipped, "
          f"failure={t6['codes'] and t6['codes']['failure']}")
    t8 = result["T8"]
    print(f"T8 manifest removal: {'PASS' if t8['pass'] else 'FAIL'}  c2patool: {t8['c2patool_stderr'][:60]!r}, "
          f"decode errors: {len(t8['decode_errors'])}, streams match signed: {t8['streams_match_signed']}")
    if "T9" in result:
        t9 = result["T9"]
        print(f"T9 re-sign:         {'PASS' if t9['pass'] else 'FAIL'}  exit {t9['exit']}, "
              f"refused for its manifest: {t9['refused_for_manifest']}, wrote output: {t9['wrote_output']}")
    if "T10" in result:
        t10 = result["T10"]
        print(f"T10 embedding:      {'PASS' if t10['pass'] else 'FAIL'}  streams match unsigned: {t10['streams_match']}, "
              f"{t10['packets']} packets, payload differences: {t10['payload_differences'][:2]}")
        for e in t10["errors"]:
            print(f"    - {e}")
    if "T7" in result:
        t7 = result["T7"]
        kind = "same-size box" if t7["aligned"] else "different-size box"
        print(f"T7 transplant:      {'PASS' if t7['pass'] else 'FAIL'}  {kind} from {Path(t7['donor']).name}, "
              f"failure={t7['codes'] and t7['codes']['failure']}{'' if t7['codes'] else ' stderr=' + t7['stderr'][:80]}")
    if not result["input_unchanged"]:
        print("    - THE INPUT CHANGED")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("assets", type=Path, nargs="+")
    parser.add_argument("--anchors", type=Path, help="PEM trust anchors passed to c2patool")
    parser.add_argument("--out", type=Path, required=True, help="directory for tampered copies and reports")
    parser.add_argument("--c2pa-sign", type=Path, help="c2pa-sign binary, to run T9")
    parser.add_argument("--unsigned", type=Path, help="the file before signing, to run T10 (one asset only)")
    parser.add_argument("--transplant-from", type=Path, help="another signed file, to run T7 (one asset only)")
    args = parser.parse_args()
    if (args.unsigned or args.transplant_from) and len(args.assets) != 1:
        print("error: --unsigned and --transplant-from take one asset", file=sys.stderr)
        sys.exit(2)
    for extra in (args.unsigned, args.transplant_from):
        if extra and not extra.is_file():
            print(f"error: no such file: {extra}", file=sys.stderr)
            sys.exit(2)
    missing = missing_tools(args.c2pa_sign)
    if missing:
        print(f"error: missing {', '.join(missing)}", file=sys.stderr)
        sys.exit(2)
    results = {}
    for asset in args.assets:
        if asset.suffix.lower() not in BMFF_SUFFIXES or not asset.is_file():
            print(f"error: not a MOV/MP4/M4A file: {asset}", file=sys.stderr)
            sys.exit(2)
        results[asset.name] = check(asset, args.anchors, args.out / asset.stem, args.c2pa_sign,
                                    args.unsigned, args.transplant_from)
        print_result(results[asset.name])
    (args.out / "containers.json").write_text(json.dumps(results, indent=2))
    ok = all(r["pass"] for r in results.values())
    print(f"\nresult: {'PASS' if ok else 'FAIL'}   (outputs in {args.out})")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
