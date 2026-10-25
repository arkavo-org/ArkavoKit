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
// Only the file's SHA-256 is sent; the server returns a signed manifest that
// is appended to the file. Check the result with `c2patool <file>` or the
// `c2pa-sign` CLI in this package.
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
