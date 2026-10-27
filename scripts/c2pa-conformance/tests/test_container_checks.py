"""Checks on the container checker itself, with hand-built ISO BMFF files.

  python3 -m unittest discover -s scripts/c2pa-conformance/tests
"""
import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import container_checks as cc  # noqa: E402

SAMPLE_SIZES = [10, 20, 30, 40]


def box(kind, payload):
    return struct.pack(">I4s", 8 + len(payload), kind.encode()) + payload


def full_box(kind, payload):
    return box(kind, b"\0\0\0\0" + payload)


def manifest_box(store=b"jumbf manifest store"):
    return box("uuid", cc.C2PA_UUID + b"\0\0\0\0" + b"manifest\0" + struct.pack(">Q", 0) + store)


def moov(chunk_offsets, wide=False):
    """One sound track: one chunk per sample, offsets in stco (or co64 when `wide`)"""
    if wide:
        offsets = full_box("co64", struct.pack(">I", len(chunk_offsets))
                           + b"".join(struct.pack(">Q", o) for o in chunk_offsets))
    else:
        offsets = full_box("stco", struct.pack(">I", len(chunk_offsets))
                           + b"".join(struct.pack(">I", o) for o in chunk_offsets))
    stsc = full_box("stsc", struct.pack(">I", 1) + struct.pack(">III", 1, 1, 1))
    stsz = full_box("stsz", struct.pack(">II", 0, len(SAMPLE_SIZES))
                    + b"".join(struct.pack(">I", s) for s in SAMPLE_SIZES))
    hdlr = full_box("hdlr", b"\0\0\0\0" + b"soun" + b"\0" * 12 + b"\0")
    stbl = box("stbl", offsets + stsc + stsz)
    return box("moov", box("trak", box("mdia", hdlr + box("minf", stbl))))


def sample_offsets(mdat_payload_start):
    offsets, offset = [], mdat_payload_start
    for size in SAMPLE_SIZES:
        offsets.append(offset)
        offset += size
    return offsets


FTYP = box("ftyp", b"qt  \0\0\0\0qt  ")
MDAT = box("mdat", bytes(range(sum(SAMPLE_SIZES))))


def signed_layout(wide=False):
    """ftyp, manifest, mdat, moov: what the signer writes"""
    head = FTYP + manifest_box()
    return head + MDAT + moov(sample_offsets(len(head) + 8), wide)


class PlacementTests(unittest.TestCase):
    def test_the_signed_layout_passes(self):
        report, problems = cc.placement(signed_layout())
        self.assertEqual(problems, [])
        self.assertEqual([t for t, _, _ in report["top_level"]], ["ftyp", "uuid", "mdat", "moov"])
        self.assertEqual(report["tracks"], [{"handler": "soun", "offsets": "stco", "samples": 4, "outside_mdat": 0}])

    def test_64_bit_chunk_offsets_are_read(self):
        report, problems = cc.placement(signed_layout(wide=True))
        self.assertEqual(problems, [])
        self.assertEqual(report["tracks"][0]["offsets"], "co64")

    def test_a_manifest_moved_to_the_end_with_stale_offsets_fails(self):
        # The offsets still assume the box sits after ftyp, so they point past the media
        stale = sample_offsets(len(FTYP) + len(manifest_box()) + 8)
        data = FTYP + MDAT + moov(stale) + manifest_box()
        _, problems = cc.placement(data)
        self.assertTrue(any("expected exactly [1]" in p for p in problems), problems)
        self.assertTrue(any("outside mdat" in p for p in problems), problems)

    def test_a_corrupted_chunk_offset_fails(self):
        data = signed_layout()
        offsets = sample_offsets(len(FTYP) + len(manifest_box()) + 8)
        offsets[2] = 0xFFFF0000
        data = data[:-len(moov(offsets))] + moov(offsets)
        _, problems = cc.placement(data)
        self.assertEqual(problems, ["soun track: 1 of 4 samples outside mdat, first (4294901760, 30)"])

    def test_two_manifest_boxes_fail(self):
        head = FTYP + manifest_box() + manifest_box()
        data = head + MDAT + moov(sample_offsets(len(head) + 8))
        _, problems = cc.placement(data)
        self.assertTrue(any("expected exactly [1]" in p for p in problems), problems)

    def test_a_box_that_runs_past_the_end_is_a_problem_not_a_crash(self):
        data = signed_layout()
        data = data[:-4]
        _, problems = cc.placement(data)
        self.assertEqual(len(problems), 1)
        self.assertIn("bad size", problems[0])

    def test_a_truncated_box_header_is_a_problem_not_a_crash(self):
        _, problems = cc.placement(signed_layout() + b"\0\0\0")
        self.assertEqual(len(problems), 1)
        self.assertIn("truncated box header", problems[0])


    def test_a_track_without_a_sample_size_table_is_a_problem_not_a_crash(self):
        data = signed_layout()
        stsz = data.index(b"stsz") - 4
        size = struct.unpack(">I", data[stsz:stsz + 4])[0]
        # Rename stsz to a free box, so the track has no sample sizes
        broken = data[:stsz + 4] + b"free" + data[stsz + 8:]
        self.assertEqual(len(broken), len(data))
        _, problems = cc.placement(broken)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("stsz", problems[0])
        self.assertGreater(size, 8)


class ProbeOutputTests(unittest.TestCase):
    def test_increasing_dts_has_no_problems(self):
        self.assertEqual(cc.dts_problems(["0,0", "1,0", "0,512", "1,1024"]), [])

    def test_a_repeated_dts_is_a_problem(self):
        self.assertEqual(cc.dts_problems(["0,0", "0,512", "0,512"]), ["stream 0: packet dts 512 after 512"])

    def test_blank_and_short_lines_are_skipped(self):
        self.assertEqual(cc.dts_problems(["", "0,0", "0", "0,N/A", "0,512"]), [])

    def test_an_ffprobe_failure_is_reported_not_raised(self):
        class Failed:
            returncode, stdout, stderr = 1, "", "Invalid data found when processing input"
        real = cc.subprocess.run
        cc.subprocess.run = lambda *args, **kwargs: Failed()
        try:
            found, error = cc.streams(Path("broken.mov"))
        finally:
            cc.subprocess.run = real
        self.assertIsNone(found)
        self.assertIn("Invalid data", error)


class TransplantTests(unittest.TestCase):
    def test_a_same_size_donor_box_is_swapped_in_place(self):
        data = signed_layout()
        donor = FTYP + manifest_box(b"other manifest store") + MDAT + moov(sample_offsets(0))
        self.assertEqual(len(manifest_box(b"other manifest store")), len(manifest_box()))
        copy, aligned = cc.transplanted(data, donor)
        self.assertTrue(aligned)
        self.assertEqual(len(copy), len(data))
        start = len(FTYP)
        self.assertEqual(copy[start:start + len(manifest_box())], manifest_box(b"other manifest store"))
        self.assertEqual(copy[start + len(manifest_box()):], data[start + len(manifest_box()):])

    def test_a_different_size_donor_box_shifts_the_media(self):
        data = signed_layout()
        bigger = manifest_box(b"a longer manifest store than ours")
        copy, aligned = cc.transplanted(data, FTYP + bigger + MDAT)
        self.assertFalse(aligned)
        self.assertEqual(len(copy), len(data) - len(manifest_box()) + len(bigger))


class Framemd5Tests(unittest.TestCase):
    SIGNED = ["#format: frame checksums", "#stream#, dts, pts, duration, size, hash",
              "0, 0, 0, 1, 460800, aa", "1, 0, 0, 1024, 4096, bb"]

    def test_identical_packets_have_no_differences(self):
        self.assertEqual(cc.framemd5_differences(self.SIGNED, list(self.SIGNED)), [])

    def test_comment_lines_are_ignored(self):
        unsigned = ["#format: other header"] + self.SIGNED[1:]
        self.assertEqual(cc.framemd5_differences(self.SIGNED, unsigned), [])

    def test_a_changed_packet_is_reported(self):
        unsigned = self.SIGNED[:2] + ["0, 0, 0, 1, 460800, ff", self.SIGNED[3]]
        self.assertEqual(cc.framemd5_differences(self.SIGNED, unsigned),
                         ["packet 1 differs: signed '0, 0, 0, 1, 460800, aa', unsigned '0, 0, 0, 1, 460800, ff'"])

    def test_a_missing_packet_is_reported(self):
        self.assertEqual(cc.framemd5_differences(self.SIGNED, self.SIGNED[:3]),
                         ["signed has 2 packets, unsigned 1"])


class TamperCopyTests(unittest.TestCase):
    def test_tampering_flips_one_byte_inside_the_first_mdat_payload(self):
        data = signed_layout()
        tampered, offset = cc.tampered(data)
        mdat_start = len(FTYP) + len(manifest_box()) + 8
        self.assertTrue(mdat_start <= offset < mdat_start + len(MDAT) - 8)
        self.assertEqual([i for i in range(len(data)) if data[i] != tampered[i]], [offset])

    def test_removal_turns_the_manifest_box_into_a_same_size_free_box(self):
        data = signed_layout()
        removed = cc.manifest_removed(data)
        self.assertEqual(len(removed), len(data))
        start = len(FTYP)
        self.assertEqual(removed[start + 4:start + 8], b"free")
        self.assertEqual([i for i in range(len(data)) if data[i] != removed[i]], list(range(start + 4, start + 8)))


if __name__ == "__main__":
    unittest.main()
