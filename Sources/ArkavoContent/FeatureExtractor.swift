import AVFoundation
import CoreML
import Foundation
import Vision

// MARK: - Feature Extractor Protocol

public protocol FeatureExtractor {
    func extractFeatures(from image: CGImage) async throws -> [Float]
}

// MARK: - VGG16 Feature Extractor

public class VGG16FeatureExtractor: FeatureExtractor {
    private let model: VNCoreMLModel

    public init() throws {
        // Note: You'll need to provide your own VGG16 CoreML model
        guard let modelURL = Bundle.main.url(forResource: "DETRResnet50SemanticSegmentationF16", withExtension: "mlmodelc"),
              let vggModel = try? MLModel(contentsOf: modelURL)
        else {
            throw FeatureExtractionError.modelNotFound
        }
        model = try VNCoreMLModel(for: vggModel)
    }

    public func extractFeatures(from image: CGImage) async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: model) { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let results = request.results as? [VNCoreMLFeatureValueObservation],
                      let features = results.first?.featureValue.multiArrayValue
                else {
                    continuation.resume(throwing: FeatureExtractionError.featureExtractionFailed)
                    return
                }

                // Convert MLMultiArray to [Float]
                let length = features.count
                var featureArray: [Float] = []
                for i in 0 ..< length {
                    featureArray.append(features[i].floatValue)
                }

                continuation.resume(returning: featureArray)
            }

            do {
                let handler = VNImageRequestHandler(cgImage: image)
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Copyright Detection System

public class CopyrightDetectionSystem {
    private let featureExtractor: FeatureExtractor
    private var database: [String: [Float]] = [:]
    private let similarityThreshold: Float

    public init(featureExtractor: FeatureExtractor, similarityThreshold: Float = 0.95) {
        self.featureExtractor = featureExtractor
        self.similarityThreshold = similarityThreshold
    }

    // Add copyrighted image to database
    func registerCopyrightedImage(_ image: CGImage, identifier: String) async throws {
        let features = try await featureExtractor.extractFeatures(from: image)
        database[identifier] = features
    }

    // Check if an image potentially violates copyright
    func checkCopyright(_ image: CGImage) async throws -> [CopyrightMatch] {
        let features = try await featureExtractor.extractFeatures(from: image)
        print("Features: \(features.count)")
        var matches: [CopyrightMatch] = []

        for (identifier, storedFeatures) in database {
            let similarity = cosineSimilarity(features, storedFeatures)
            if similarity >= similarityThreshold {
                matches.append(CopyrightMatch(identifier: identifier, similarity: similarity))
            }
        }

        return matches.sorted { $0.similarity > $1.similarity }
    }

    // Cosine similarity calculation
    private func cosineSimilarity(_ v1: [Float], _ v2: [Float]) -> Float {
        guard v1.count == v2.count else { return 0.0 }

        let dotProduct = zip(v1, v2).map(*).reduce(0, +)
        let magnitude1 = sqrt(v1.map { $0 * $0 }.reduce(0, +))
        let magnitude2 = sqrt(v2.map { $0 * $0 }.reduce(0, +))

        guard magnitude1 > 0, magnitude2 > 0 else { return 0.0 }
        return dotProduct / (magnitude1 * magnitude2)
    }
}

// MARK: - Supporting Types

public struct CopyrightMatch: Identifiable, Sendable {
    public let id = UUID()
    public let identifier: String
    public let similarity: Float
}

public enum FeatureExtractionError: Error {
    case modelNotFound
    case featureExtractionFailed
}

// MARK: - Video Processing Extension

public extension CopyrightDetectionSystem {
    func processVideo(url: URL, frameInterval: TimeInterval = 1.0) async throws -> [VideoFrame] {
        print("Processing video: \(url)")
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var frames: [VideoFrame] = []
        var currentTime = CMTime.zero

        while currentTime < duration {
            let image = try generator.copyCGImage(at: currentTime, actualTime: nil)
            let matches = try await checkCopyright(image)

            if !matches.isEmpty {
                frames.append(VideoFrame(
                    timestamp: currentTime.seconds,
                    matches: matches,
                ))
            }

            currentTime = CMTimeAdd(currentTime, CMTime(seconds: frameInterval, preferredTimescale: 600))
        }

        return frames
    }
}

public struct VideoFrame: Sendable {
    public let timestamp: Double
    public let matches: [CopyrightMatch]
}
