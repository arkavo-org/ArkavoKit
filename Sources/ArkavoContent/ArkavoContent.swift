import AVFoundation
import CoreImage
import CoreML
import Vision

public class VideoClassificationProcessor {
    // MARK: - Properties

    private var videoURL: URL
    private var classificationRequest: VNCoreMLRequest?

    // MARK: - Types

    public struct ClassificationResult: Sendable {
        public let timestamp: TimeInterval
        public let label: String
        public let confidence: Float
    }

    public enum VideoProcessingError: Error, Sendable {
        case invalidVideoFile
        case modelLoadError
        case processingError(String)
    }

    // MARK: - Initialization

    public init(videoPath: String) throws {
        guard !videoPath.isEmpty else {
            throw VideoProcessingError.invalidVideoFile
        }
        if let parsed = URL(string: videoPath), parsed.isFileURL {
            videoURL = parsed
        } else {
            videoURL = URL(fileURLWithPath: videoPath)
        }
    }

    // MARK: - Public Methods

    public func loadModel(modelName: String) throws {
        guard let modelURL = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
            throw VideoProcessingError.modelLoadError
        }

        do {
            let model = try VNCoreMLModel(for: MLModel(contentsOf: modelURL))
            classificationRequest = VNCoreMLRequest(model: model)
            classificationRequest?.imageCropAndScaleOption = .centerCrop
        } catch {
            throw VideoProcessingError.modelLoadError
        }
    }

    public func processVideo(every frameInterval: Int = 30) async throws -> [ClassificationResult] {
        guard frameInterval > 0, frameInterval <= Int(Int32.max) else {
            throw VideoProcessingError.processingError("frameInterval must be between 1 and \(Int32.max)")
        }
        guard let request = classificationRequest else {
            throw VideoProcessingError.modelLoadError
        }

        let asset = AVURLAsset(url: videoURL)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw VideoProcessingError.invalidVideoFile
        }
        guard duration.isValid, !duration.isIndefinite, duration > .zero else {
            return []
        }

        let nominalFPS: Double
        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
           let rate = try? await videoTrack.load(.nominalFrameRate),
           rate.isFinite, rate > 0 {
            nominalFPS = Double(rate)
        } else {
            nominalFPS = 30.0
        }
        let stepSeconds = Double(frameInterval) / nominalFPS
        let stepTime = CMTime(seconds: stepSeconds, preferredTimescale: 600)
        let frameDuration = (stepTime.isValid && stepTime > .zero) ? stepTime : CMTime(value: 1, timescale: 600)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        var results: [ClassificationResult] = []
        var frameNumber = 0
        var currentTime = CMTime.zero

        while currentTime < duration {
            try Task.checkCancellation()
            do {
                let imageRef = try await generator.image(at: currentTime).image
                let requestHandler = VNImageRequestHandler(cgImage: imageRef)
                try requestHandler.perform([request])

                if let observations = request.results as? [VNClassificationObservation] {
                    let frameResults = observations.prefix(3).map { observation in
                        ClassificationResult(
                            timestamp: CMTimeGetSeconds(currentTime),
                            label: observation.identifier,
                            confidence: observation.confidence
                        )
                    }
                    results.append(contentsOf: frameResults)
                }

                currentTime = CMTimeAdd(currentTime, frameDuration)
                frameNumber += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw VideoProcessingError.processingError("Error processing frame \(frameNumber)")
            }
        }

        return results
    }
}
