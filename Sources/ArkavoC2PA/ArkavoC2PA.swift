// ArkavoC2PA - C2PA Content Provenance Integration
//
// This package provides C2PA (Coalition for Content Provenance and Authenticity)
// integration for ArkavoCreator, enabling cryptographic signing and chain of custody
// for recorded content.
//
// ## Components
//
// - `C2PAServerSigner`: Signs MOV/MP4/M4A through the arkavo-rs signing server
// - `C2PASigningService`: Client for the server's `POST /c2pa/v1/sign`
// - `C2PAVerifier`: Reads a signed file back: a local manifest check, and
//   `POST /c2pa/v1/validate` for the full result
// - `C2PAManifest`: Structured manifest for provenance metadata
// - `C2PAManifestBuilder`: Fluent API for building manifests
// - `C2PASigner`: Signs content (pending native implementation)
// - `C2PAValidationResult`: Verification results
//
// ## Server signing
//
// ```swift
// let signer = C2PAServerSigner() // https://platform.arkavo.net
// let embedded = try await signer.sign(
//     inputFile: recordingURL,
//     outputFile: signedURL,
//     metadata: C2PASigningMetadata(title: "My Recording", creator: "creator@example.com")
// )
// ```
//
// Only a SHA-256 of the file leaves the device. The signed manifest goes in a
// C2PA box right after `ftyp`, and the chunk offsets in `moov` are moved to
// match. Check the result with `c2patool <file>` or the `c2pa-sign` CLI in this
// package.
//
// ## Verifying
//
// ```swift
// if try C2PAVerifier.hasManifest(recordingURL) { /* show the badge */ }
// switch try await C2PAVerifier().verify(recordingURL) {
// case .valid(let provenance): print(provenance.creator ?? "", provenance.signedAt ?? "")
// case .invalid(let errors, _): print("Not verified: \(errors)")
// case .noManifest: print("Unsigned")
// }
// ```
//
// `verify` sends the manifest and a SHA-256 of the rest of the file; the
// endpoint needs no sign-in.
//
// ## Native signing usage
//
// ```swift
// // Build manifest
// var builder = C2PAManifestBuilder(title: "My Recording")
// builder.addCreatedAction()
// builder.addAuthor(name: "Creator Name")
// builder.addDeviceMetadata(model: "MacBook Pro", os: "macOS 26")
// let manifest = builder.build()
//
// // Sign content
// let signer = try C2PASigner(signingMode: .selfSigned)
// try await signer.sign(
//     inputFile: videoURL,
//     outputFile: signedURL,
//     manifest: manifest
// )
//
// // Verify
// let result = try await signer.verify(file: signedURL)
// print("Valid: \(result.isValid)")
// ```
//
// ## Implementation
//
// This package will integrate with c2pa-opentdf-rs for native C2PA signing:
// https://github.com/arkavo-org/c2pa-opentdf-rs
//
// The Rust library provides:
// - Native C2PA manifest creation and signing via c2pa-rs
// - OpenTDF integration for content encryption
// - Works in sandboxed macOS/iOS apps via XCFramework + Swift FFI

import Foundation
