# Components the scanner cannot see

`osv-scanner` and `syft` read `Package.resolved` (see
`.github/workflows/vulnerability-scan.yml`). They do not see the item below, so it is listed
here by hand. This file is uploaded with each release SBOM. Review it whenever the
`iroh-swift` pin in `Package.resolved` moves, and on the same schedule as the dependency
findings: CRITICAL and HIGH issues within 90 days.

ArkavoKit declares no `binaryTarget` and no vendored code of its own. The only binary it pulls
in is through `iroh-swift`. Checked against the `Package.swift` of every other package in
`Package.resolved` (OpenTDFKit, ArkavoMediaKit, CryptoSwift, SwiftCBOR, ZIPFoundation): none
declares a binary target. Repeat that check when a new package appears in the lockfile.

## Binary frameworks

| Component | Where it comes from | What is inside | Review |
| --- | --- | --- | --- |
| `IrohSwiftFFI.xcframework` | Binary target of the `iroh-swift` package (`from: 0.5.0` in `Package.swift`), downloaded as `https://github.com/arkavo-org/iroh-swift/releases/download/<version>/IrohSwiftFFI.xcframework.zip` and verified by the checksum in that package's `Package.swift`. The version is the `iroh-swift` pin in `Package.resolved`. | A Rust static library built from `rust/` in the iroh-swift repo: `iroh`, `iroh-blobs`, `iroh-docs`, `iroh-gossip`, `tokio`, `rustls`, `ring` and their transitive crates. The exact crate versions are in `rust/Cargo.lock` at the pinned tag. | On each iroh-swift bump, read `rust/Cargo.lock` at the new tag and check it against RustSec/OSV. iroh-swift is not yet gated in CI. |

## Outside this repo

- C2PA manifests are signed by the Arkavo signer service (`C2PAServerSigner`). That service is
  scanned by the arkavo-rs gate, not here.
- Apple system frameworks and the Xcode toolchain come from the OS and the build machine and are
  not listed.
