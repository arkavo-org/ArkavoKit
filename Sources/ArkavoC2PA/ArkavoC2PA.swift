// ArkavoC2PA - C2PA Content Provenance Integration
//
// This package provides C2PA (Coalition for Content Provenance and Authenticity)
// integration for ArkavoCreator, enabling cryptographic signing and chain of custody
// for recorded content.
//
// ## Components
//
// - `C2PAManifest`: Structured manifest for provenance metadata
// - `C2PAManifestBuilder`: Fluent API for building manifests
// - `C2PASigner`: Signs content using c2pa-opentdf-rs native library
// - `C2PAValidationResult`: Verification results
//
// ## Usage
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
// let signer = try C2PASigner()
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
// - Native C2PA manifest creation and signing (no external tools required)
// - OpenTDF integration for content encryption
// - Works seamlessly in sandboxed macOS apps

import Foundation
