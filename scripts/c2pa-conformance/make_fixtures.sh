#!/usr/bin/env bash
# Generates the unsigned inputs for the #36 tests that need signing first. The media stays out of
# the repo; sign it with c2pa-sign, then run run.sh on the signed files.
#
#   scripts/c2pa-conformance/make_fixtures.sh OUT_DIR
#
#   t7-a.mov, t7-b.mov  3 s of uncompressed video and PCM, with byte-identical layouts and
#                       different content. Signed, each one's manifest box moved into the other
#                       is the aligned T7 transplant. Either one with its signed copy is T10.
#   s5-near-4gib.mov    About 5 h 45 min of 16x16 video and PCM, 4.3 GB. Every chunk offset sits
#                       just under 2^32, so inserting a manifest box of more than about 7.6 KB
#                       pushes the last ones past 4 GiB and the signer must turn stco into co64
#                       (S5). It writes exactly 207,360 bytes a second (30 x 512 B of video plus
#                       192,000 B of audio), which is what makes the duration land the offsets.
set -euo pipefail
out="${1:?usage: make_fixtures.sh OUT_DIR}"
mkdir -p "$out"
cd "$out"

ffmpeg -nostdin -v error -y -f lavfi -i "testsrc2=size=640x360:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 3 -c:v rawvideo -pix_fmt uyvy422 -c:a pcm_s16le -ac 2 t7-a.mov
ffmpeg -nostdin -v error -y -f lavfi -i "smptebars=size=640x360:rate=30" -f lavfi -i "sine=frequency=880:sample_rate=48000" \
    -t 3 -c:v rawvideo -pix_fmt uyvy422 -c:a pcm_s16le -ac 2 t7-b.mov
ffmpeg -nostdin -v error -y -f lavfi -i "testsrc2=size=16x16:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 20712.61 -c:v rawvideo -pix_fmt uyvy422 -c:a pcm_s16le -ac 2 s5-near-4gib.mov
ls -l t7-a.mov t7-b.mov s5-near-4gib.mov
