# C2PA Conformance Self-Test Plan — reviewed draft

Original: October 24, 2026 · Paul Flynn. Review: October 24, 2026.

This revision preserves the goal of completing internal readiness work before filing the Expression of Interest. It separates internal readiness from public-trust readiness, adds two specification failures absent from the original gap table, and makes the tests produce reviewable evidence. It does not report conformance or authorize submission.

## Goal, scope and decisions

Evaluate one Distributed generator product: Arkavo Creator on macOS, ArkavoKit's `C2PAServerSigner`, and arks's `/c2pa/v1/sign`. Target Assurance Level 1. The evaluation boundary runs from capture or content input through persistence of the signed asset; document the relevant recording/compositing libraries, c2pa-rs, authentication service, KMS integration and hosting dependencies as well as the three main components.

Claim `video/quicktime` and `audio/mp4` only after actual Creator output demonstrates both. Add `video/mp4` only if the submitted product build produces it. Mapping M4A to the MP4 container protocol does not itself demonstrate audio media-type coverage.

Keep fragmented MP4, live HLS signing, images and CAWG identity assertions outside the initial feature scope. `/c2pa/v1/validate` can remain outside the claim only if the claimed product's functionality does not depend on it for validation. Inspect Creator's provenance view and ingredient/export paths: displaying metadata alone does not automatically establish validator functionality, but executing validation requires the product validation harness. A private trust store does not remove that requirement. The harness must exercise the product's actual validation path, with the supplied asset, signer trust list, TSA trust list and RFC 3339 validation time; a separate c2pa-rs utility is insufficient if its behavior differs from the product. [Program requirements](https://github.com/c2pa-org/conformance-public/blob/main/docs/v0.2/Additional%20Conformance%20Requirements%20Against%20the%20Content%20Credentials%20Specification.md)

Before implementation gates begin, record decisions on the claimed spec version, validation functionality, media types, attribution policy and source-type mapping. Version 2.2 and 2.4 are supported by program v0.2. Choose based on the shipped stack's demonstrated behavior, not just the number of failing rubric rows. Do not equate the SDK version, the validator's reported spec version, or the claim format version with the product's declared specification version.

## What passing means

**Internal readiness, before Expression of Interest:** every applicable positive and negative test has its expected result; conformance rubrics have no failures; controlled-trust integrity tests pass; c2patool and at least one independent validator have exercised every claimed media type; applicable Level 1 controls operate and have evidence in the mandatory architecture template. Known private-signer trust failures are recorded separately. Identify the second validator and its underlying engine. Two applications using c2pa-rs provide external interoperability evidence but do not establish implementation independence. Until a qualifying validator is identified and run, keep this gate open; any decision to accept only operator independence must be explicit.

**Public-trust readiness, after approval and certificate issuance:** sign fresh samples with the issued Level 1 certificate and intended TSA, then pass the public-trust profile without adding Arkavo's CA or disabling trust checks. Confirm the issued certificate's product identity, chain and assurance extension. Do not make possession of this certificate a prerequisite to applying: issuance depends on conformance approval. A signed Notice can support issuance before a delayed public listing. [Conformance Program](https://github.com/c2pa-org/conformance-public/blob/main/docs/v0.2/C2PA%20Conformance%20Program.md)

Rubric success is necessary evidence, not proof of every normative requirement. Maintain a requirements-to-evidence matrix for applicable specification and program requirements, with justified non-applicability and explicit treatment of recommendations. Preserve warnings for review. The placement and identifier failures below demonstrate why the published rubrics alone are insufficient.

There is no program application or listing fee. Engineering, hosting, CA services and timestamp capacity may still cost money. [Program fee schedule](https://github.com/c2pa-org/conformance-public/blob/main/docs/v0.2/C2PA%20Conformance%20Program.md#conformance-program-fee-schedule)

## Verified baseline and gaps

The review re-ran the evaluator against the saved `deploy_check.crjson.json`, using conformance-public commit `da71a7231fd6c86d308771dbb5557fabc920997a`:

| Rubric | Pass | Fail | Warning |
|---|---:|---:|---:|
| Program 0.2 / spec 2.2 | 20 | 3 | 0 |
| Program 0.2 / spec 2.4 | 27 | 4 | 0 |
| Integrity | 5 | 1 | 0 |

These reproduce the original totals. They are a replay of saved evidence, not a new signing run or confirmation of the current production deployment. The report identifies signing SDK 0.91.6, report generator 0.90.22, and validation time `2026-10-25T02:27:33.668325+00:00` (October 24 in New York). The installed c2patool observed during review is 0.27.22. Do not attribute that installed version retroactively to the saved report.

| Item | Evidence and required correction | Classification / repository |
|---|---|---|
| Standard manifest placement | ArkavoKit appends a `uuid` box with purpose `manifest` at EOF. The saved MOV has `mdat` at offset 28, `moov` at 29,115 and the manifest at 32,733. Standard manifest placement must be after `ftyp` and before both media and movie boxes. Reserve space there or rewrite affected offsets, then hash the final layout. Appending an `update` box is a separate mechanism and cannot relabel an initial standard manifest. | **New blocker**, ArkavoKit + arks protocol coordination |
| Claim instance identifier | The saved `claim.v2.instanceID` is `""`, also confirmed directly in the embedded CBOR; both claim schemas require a nonempty string. Generate a valid asset-version identifier and verify uniqueness across distinct assets. | **New blocker**, arks |
| Inception action attribution | `inception_action_position` fails because actions are gathered. Put the product's own capture/generation actions in `created_assertions`, with the inception action first in the first actions assertion. Do not describe this as the spec requiring all actions to be created: spec 2.2 explicitly permits either list; the observed rubric is stricter, and gathered assertions are not attributed to the signer. | Blocker for the rubric and product attribution, arks |
| Actions completeness | Populate a Boolean `allActionsIncluded` in every actions assertion. Set true only when the actual recorded action history is complete; absence of manual editing does not establish that compositing, synthesis or export actions were recorded. | Blocker, Creator + arks |
| Deprecated attribution | Remove `stds.schema-org.CreativeWork`. Either omit personal attribution or define a namespaced assertion with explicit attribution semantics. A custom name is not verified human identity and external viewers need not display it. CAWG remains a separate future feature. | Blocker, arks; product decision in Creator |
| Product and spec identification | For claim v2, `claim_generator_info` is an object. Identify the actual distributed claim-generating product and version; retain library information in namespaced fields if useful. For spec 2.4, use a SemVer value such as `2.4.0`, corresponding to the intake's 2.4 claim. Do not merely append another generator entry or change a version label without establishing conformance. | Product identification task; missing specVersion is a program blocker for 2.4, arks |
| Source-type accuracy | The current Boolean `ai_generated` cannot express all claimed workflows. Add a tested mapping for screen capture, ordinary capture, generated media, rendered avatars and mixed recordings; use the corresponding full vocabulary URI. The CLI currently always sends false. | Unresolved product correctness gap, Creator + ArkavoKit + arks |
| Automatic recording signing | Original plan reports Creator saves recordings unsigned. Exercise the shipped save workflow, including signing failure handling, before marking this complete. CLI-generated samples alone cannot establish integration. | Reported blocker, Creator#99 |
| Public signer trust | Saved report contains `signingCredential.untrusted`. Controlled trust can establish integrity now; publicly trusted issuance follows approval. | Post-approval release dependency |
| Timestamp trust | Saved report contains both `timeStamp.validated` and informational `timeStamp.untrusted`. Matching the timestamp digest does not establish TSA trust. Evaluate the actual chain against an explicit TSA-list snapshot and switch/configure the TSA if it does not chain to it. | Blocker for trusted timestamp and longevity gates, arks |
| BMFF hard binding | `c2pa.hash.data` is used. Treat the recommendation for format-aware hashing separately from the mandatory placement defect. Implement `c2pa.hash.bmff.v3` or document the rationale for departing from the recommendation and resolve reviewer questions. | Recommendation requiring disposition, arkavo-rs#103 |
| Exclusion trust boundary | Exact exclusion length does not prove the excluded bytes are a manifest, nor that the submitted digest describes the file: the backend never sees the asset. A BMFF hash still depends on the authenticated edge's correct hashing and exclusions. | Architecture and adversarial-test gap, ArkavoKit + arks |
| Validation harness | Determine actual validation functionality; if applicable, supply the four-input harness described above. | Conditional blocker, Creator + validation implementation |

Placement is specified in [spec 2.2 A.5.3](https://spec.c2pa.org/specifications/specifications/2.2/specs/C2PA_Specification.html#_box_containing_the_manifest) and [spec 2.4 A.5.3](https://spec.c2pa.org/specifications/specifications/2.4/specs/C2PA_Specification.html#_box_containing_the_manifest). Claim schema and generator metadata are in chapter 10; inception rules are in spec 2.2 §18.14.2. Consult the selected specification as well as the [rubric source](https://github.com/c2pa-org/conformance-public/tree/da71a7231fd6c86d308771dbb5557fabc920997a/asset-rubrics).

For source types, screen recordings have a `screenCapture` term. A fully generative output may use `trainedAlgorithmicMedia`; a mix including generative elements may require `compositeSynthetic`; non-generative rendering is not automatically generative AI. Choose according to the implemented operation and ingredients, rather than the recording-mode name. [IPTC vocabulary](https://cv.iptc.org/newscodes/digitalsourcetype/)

## Samples and evidence profiles

Use real, finalized recordings from the release candidate. Keep synthetic fixtures for controlled negative and boundary tests, identified separately from submission samples.

| ID | Required sample |
|---|---|
| S1 | Camera MOV, ordinary capture; include the actual audio-track configuration. |
| S2 | Screen MOV, with the selected screen/source policy recorded. |
| S3 | Separate representative avatar-only, AI-generated and mixed camera/Muse paths that the product supports. Record the expected action history and source type for each. |
| S4 | Audio-only M4A, including synthesized or mixed audio if the product supports those modes. |
| S5 | A playable recording over 4 GiB, plus a controlled case whose embedding crosses a 32-bit size/offset boundary and exercises required `stco` → `co64` conversion. Merely using a 64-bit header around a tiny payload does not test this. |
| S6 | MP4 export only if claimed. If exporting an existing asset, preserve the appropriate parent/ingredient and transformation history; do not automatically describe every export as a new capture. |

For each sample retain unsigned/signed SHA-256 hashes, byte sizes, build/commit IDs, OS and mode, expected metadata/actions, exact commands, tool versions, trust-list snapshots and fingerprints, validation time, raw reports, rubric JSON, playback evidence and external-validator results. Freeze the artifact set per run. The saved baseline hashes are:

```text
deploy_check.mov
e7876639cee83d4c252d8ca15e48f14f8a75d25d36d7f4cdedde1dc07845c124
deploy_check.crjson.json
1b0a477e91713313c4e51004d9b6a278c32b9769a8c823a4ba0dbf47039219d8
```

Define explicit trust profiles:

- **Controlled:** Arkavo test signer anchor plus an explicitly configured TSA anchor/list, trust checking enabled. This proves behavior under those anchors, not C2PA public trust.
- **Public:** captured official signer and TSA trust lists, with no private additions or trust bypasses. Before issuance, allow only the documented private-signer failure in the readiness report; after issuance, require full trust. Track TSA trust independently in both phases.
- **Time-controlled:** test signer/TSA chains and injected validation time, with frozen revocation/network policy. Use this for expiry tests without changing the machine clock.

Ambient c2patool settings and environment variables must not silently select trust behavior. Record effective configuration; the installed tool reads a user settings file by default.

## Self-test suite

Run asset-dependent checks on every applicable sample. Run service, policy and boundary checks against their dedicated fixtures; an HTTP test is not something every media file must independently pass. Expected rejection is a pass for a negative test. Unsupported validator media sizes are untested coverage, not successes.

| ID | Test and level | Pass criteria |
|---|---|---|
| T1 | Program rubric — asset integration | Selected-version rubric returns zero entries under every `false` category, with all expected checks executed. Tool errors, malformed output and empty/missing evaluations fail the run. Review warnings. |
| T2 | Integrity rubric — asset integration | Controlled profile has zero failures. Public pre-issuance profile reports only the documented signer-trust exception; post-issuance has none. Require timestamp trust separately: this rubric does not catch informational `timeStamp.untrusted`. |
| T3 | Explicit public validation — integration | Verify binding and signature success and enumerate all failures/information. Do not promise “only signingCredential.untrusted” while the TSA is untrusted. |
| T4 | Controlled validation — integration | Expected signer trust, signature and binding success; no failures or unexplained informational codes. Successful validation normally includes status codes, so “no status codes” is not the criterion. |
| T5 | Independent validator — interoperability | Record service/build, media support, underlying engine and trust behavior. Check manifest parsing and integrity, title, source type and declared signer. Compare personal attribution only where the chosen assertion is supported. A shared validation engine cannot close the implementation-independence gate; record any proposed change to that criterion explicitly. |
| T6 | Media tamper — negative integration | Flip a known hashed `mdat` payload byte while preserving box structure. Expect `assertion.dataHash.mismatch`, or `assertion.bmffHash.mismatch` after migration. A parse error alone does not exercise binding validation. |
| T7 | Manifest transplant — negative integration | Use distinct-content fixtures with matched layout/exclusion offsets so the transplanted manifest is well-formed; require a binding mismatch. Separately test malformed/misaligned transplants as rejection cases. |
| T8 | Manifest removal — container integration | Remove the manifest without shifting media offsets (for a front-positioned manifest, replace it with a same-sized `free` box or correctly rewrite offsets). Disable remote/sidecar recovery for the fixture. Report no embedded manifest and preserve playback. |
| T9 | Double signing — unit + integration | Reject already-signed input before a sign request; leave input intact and create no output. Preserve the existing local regression. |
| T10 | Playback and stream preservation — integration/manual | AVFoundation and QuickTime playback succeed; ffprobe shows matching streams, timing and duration. Compare encoded media payloads where signing should preserve them, including beginning/middle/end access for large files. Full-file byte identity is not expected after offset rewriting. |
| T11 | Service abuse — backend integration | Missing/invalid token: 401; incorrect single exclusion length: 422 with no returned manifest; multiple exclusions: 400 under the current API; quota exhaustion: 429. Test creator authorization, malformed digest, invalid/ranged integers and a same-length exclusion at the wrong location. Document which protections require authenticated-edge evidence. Assert rejection behavior and side effects, not HTTP codes alone. |
| T12 | Certificate longevity — validator integration | With a trusted timestamp acquired during signer-chain validity, validation after signer expiry succeeds under the selected spec and trust policy. Missing/untrusted/invalid timestamps do not provide that exemption. Use `claimSignature.outsideValidity` as the spec expectation where applicable and document SDK-specific `signingCredential.expired` output. Test validation-time boundaries and distinguish TSA expiry/revocation. A Rust unit test alone is not end-to-end evidence. |
| T13 | Claim semantics/schema — asset integration | Nonempty valid `instanceID`; actual product/version in claim-v2 generator-info object; correct specVersion when required; no deprecated assertions; correctly attributed and ordered actions; truthful Boolean completeness and source-type values. Validate raw claim structure as well as crJSON views. |
| T14 | BMFF placement and boundaries — container integration | Standard manifest after `ftyp`, before any `moov` and first `mdat`; offsets and sizes valid; final-layout binding verifies. Include existing 64-bit files, newly crossed 32-bit boundaries, malformed/truncated boxes and supported `moov` arrangements. |
| T15 | Edge authentication — security integration | Genuine supported app succeeds. Reject absent/invalid proof, wrong app/environment/user/key, replayed or expired challenge, altered digest/metadata/exclusions and stale counters before claim signing. Each size-negotiation retry receives proof bound to its actual request. |
| T16 | Transport — security integration | Signing and every other in-scope subsystem channel enforce TLS 1.3+ or a documented equivalent. TLS 1.2-only endpoint fails. Verify normal certificate/hostname validation and prohibit insecure redirect/downgrade paths. Configuration inspection alone is insufficient. |
| T17 | Signing failures and file stability — integration | Network/TSA failure, 422 negotiation exhaustion, 429, cancellation, disk-full and changing input cannot result in a reported signed success or a partially published artifact. Preserve recoverable recording data; use a stable finalized input through hashing and output creation. |
| T18 | Operational controls — CI + evidence review | Demonstrate vulnerability scan coverage, remediation/release gate operation, key access/rotation and hosting controls, with dated outputs and assigned owners. |
| T19 | Product validation harness — conditional integration | If validation is in scope, execute administrator-style input sets through the product's validation path and return crJSON using the supplied two trust lists and validation time. |

## Reliable rubric execution

Pin conformance-public, the evaluator dependencies and validator versions for each run; record their hashes. Refresh to current upstream at submission and rerun. A shallow clone alone is not a reproducibility record. The local evaluator at the baseline commit exits **0 even when rubric checks fail**, which this review reproduced for all three reports.

Example after preparing the pinned checkout, venv, explicit validation settings and sample:

```sh
SPEC_VERSION=2.2  # Replace with the recorded product decision.
R=conformance-public/asset-rubrics
c2patool --settings evidence/controlled-settings.toml sample.mov --crjson > evidence/sample.crjson.json
venv/bin/python "$R/c2pa_conformance_rubric_evaluator.py" \
  "$R/asset-rubric-conformance0.2-spec${SPEC_VERSION}.yml" \
  evidence/sample.crjson.json --spec-version "$SPEC_VERSION" \
  > evidence/conformance.json
venv/bin/python "$R/c2pa_conformance_rubric_evaluator.py" \
  "$R/asset-rubric-integrity.yml" evidence/sample.crjson.json \
  > evidence/integrity.json
```

Run these under a runner that checks each process result and validates both JSON outputs against the pinned schema. Require the expected trait inventory and no `false` entries; do not use the evaluator's exit status as the pass signal. Keep public-profile results in separate files, and apply its pre-issuance exception only to the specifically documented trust finding. The settings file above is a required run input, not supplied or validated by this document.

Use `swift test --filter ArkavoC2PATests` and arks's applicable `cargo test --features c2pa_signing` as component checks. They do not substitute for real recordings, external validation, live transport evidence or the controlled-time expiry test. The current ArkavoKit tests cover a roughly 3 MiB multi-read hash and a small extended-size header, not S5.

## Level 1 security assessment

Replace “only two security blockers” with “all applicable unmet requirements or missing mandatory evidence block readiness.” Separate implemented controls awaiting evidence from controls that still require engineering. The following applies the [Generator Product Security Requirements v0.2](https://github.com/c2pa-org/conformance-public/blob/main/docs/v0.2/C2PA%20Generator%20Product%20Security%20Requirements.md); do not treat this abbreviated checklist as a substitute for the requirement matrix.

| Area | Required evidence/action and current disposition |
|---|---|
| Architecture | Complete the mandatory Markdown template, with TOE boundaries and diagrams as needed. **Open blocker.** |
| O.1 Enrolment | Automated-enrolment requirements apply if enrolment/rotation is automated. For portal-only issuance, document manual issuance and renewal and justify non-applicability; do not invent an automated-enrolment gap. |
| O.2 Edge authentication | Prove a valid edge instance and mutual authentication. User tokens alone are insufficient. **Open blocker.** App Attest is a proposed mechanism, not a mandated Level 1 technology. |
| O.2 Key access | KMS confidentiality is reported implemented; attach key configuration and access evidence. Verify effective, time-bound least privilege, including service credentials and all authorized principals. An ambient credential chain alone proves neither short lifetimes nor least privilege. |
| O.2 Rotation | Supply the rotation procedure and evidence of capability, including certificate/key matching, rollback and emergency response. Rehearsal is an internal assurance measure. |
| O.3 Claim generator | NVD-relevant SCA/SBOM vulnerability analysis; applicable critical/high remediation within 90 days; demonstrate a release/deployment gate for overdue findings. **Open engineering/evidence blocker.** |
| O.4 Content pipeline | Scan all in-scope content/assertion software, including relevant bundled/native dependencies; document remediation. **Open engineering/evidence blocker.** |
| O.5 Transport | TLS 1.3+ or equivalent across subsystem channels. ArkavoKit currently defaults to `URLSession.shared`; changing only the signing client does not assess backend-to-KMS or other in-scope links. **Open blocker.** |
| O.6 Hosting | Evidence of RBAC, dependency/API security review, exploit mitigations and patching. Its stated timelines are 30/90/180 days for high/moderate/low, not a blanket 90 days. Use the tighter applicable deadline for overlapping controls; define critical handling explicitly. **Open until evidenced.** |

App Attest design should reuse a registered key, bind assertions to the exact signing request and a server challenge, verify app identity/environment and enforce replay protection. Plan for reinstall, key loss, retry and unsupported-device behavior. Apple's macOS support starts with macOS 27; verify eligible hardware and full-security/SIP requirements for the distribution build. Do not claim an irrevocable device-wide key budget without the specific Apple support evidence; distinguish Apple's limits, fraud metrics and Arkavo's own registration caps. [Apple App Attest session](https://developer.apple.com/videos/play/wwdc2026/201/)

Use isolated test credentials and a test signer for automation when production requires Creator attestation. Production credentials must not be exposed through a CLI bypass. Level 2 is deferred: it includes substantially more than KMS hardware and enrolment evidence, including subsystem attestation, software integrity/patch evidence and additional hosting controls.

## Execution gates and ownership

Owners below are roles to assign, not named commitments. Architecture writing and operational work can start immediately alongside implementation.

| Phase / gate | Lead repository or role | Exit evidence |
|---|---|---|
| 0 — Freeze the claim | Product/conformance owner | Named owners; spec version, media types, source/attribution policy and validation scope; initial requirement matrix and test environment. |
| 1 — Gate A: valid manifests and containers | arks + ArkavoKit | Four observed manifest-rubric corrections as applicable, nonempty instanceID, correct BMFF placement/offsets, explicit hard-binding decision; T1/T2/T6–T9/T13/T14 pass on development fixtures. |
| 2 — Gate B: complete product behavior | Creator + ArkavoKit + arks | Real S1–S6 as applicable; signing workflow, source mapping, playback, attestation, transport, negative cases and external interoperability pass. Timestamp longevity demonstrated with controlled trust. |
| 3 — Gate C: internal readiness | Security/operations + conformance owner | Mandatory architecture document completed; applicable Level 1 controls evidenced; no unresolved internal blocker; reproducible evidence bundle; validation harness if applicable. Only then file the Expression of Interest, following the original sequencing preference. |
| 4 — Review and public-trust gate | Authorized representative + CA/operations | Expression of Interest, agreements, intake and evidence review; administrator/approver acceptance and signed Notice; CA issuance; fresh public-trust samples and regression rerun before claiming public-trust readiness. |

The program permits preliminary questions; deciding to defer contact is an internal choice, not a program requirement. Keep unresolved scope questions explicit and do not silently waive their tests. Submission does not guarantee approval; respond to any additional administrator evidence requests. Reassess material product changes after conformance. [Program process](https://github.com/c2pa-org/conformance-public/blob/main/docs/v0.2/C2PA%20Conformance%20Program.md)

## Cost, dependencies and residual decisions

SSL.com's product page currently lists one free Level 1 certificate valid for one year and **2,500 timestamps/year**; its premium plan lists **10,000**. Use 2,500 for planning until the actual account terms are confirmed. With two or three billed timestamp operations per completed file, this implies roughly 1,250 or 833 files before retries/failures; confirm actual charging behavior. Pin the TSA endpoint, authentication mechanism and supported API in the integration evidence. [SSL.com plans](https://www.ssl.com/products/content-authenticity/content-credentials/c2pa/)

Remaining decisions: claimed spec; validation scope; human attribution; source types for each mixed workflow; BMFF hashing recommendation disposition; implementation independence and large-video support of the second validator; effective TLS protection on backend links; TSA account/API terms. These are explicit gate inputs, not reasons to label the current system conformant.

This review inspected ArkavoKit commit `151586eced614a1795c480781bdb158c194f06b1`, replayed saved rubric evidence and inspected saved container structure. It did not rerun the complete suite, audit the live hosting configuration, verify IAM/CloudTrail controls or submit anything to C2PA. The security summary adapts the C2PA Technical Working Group's public v0.2 documents, distributed under [CC BY 4.0](https://github.com/c2pa-org/conformance-public/blob/main/LICENSE); the classifications and test gates are Arkavo-specific review recommendations.
