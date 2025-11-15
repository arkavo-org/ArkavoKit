import AVFoundation
import CoreImage
import CoreML
import Vision

public class VideoClassificationProcessor {
    // MARK: - Properties

    private var videoURL: URL
    private var classificationRequest: VNCoreMLRequest?

    // MARK: - Types

    public struct ClassificationResult {
        public let timestamp: TimeInterval
        public let label: String
        public let confidence: Float
    }

    public enum VideoProcessingError: Error {
        case invalidVideoFile
        case modelLoadError
        case processingError(String)
    }

    // MARK: - Initialization

    public init(videoPath: String) throws {
        guard let url = URL(string: videoPath) else {
            throw VideoProcessingError.invalidVideoFile
        }
        videoURL = url
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

    @MainActor
    public func processVideo(every frameInterval: Int = 30) async throws -> [ClassificationResult] {
        guard let request = classificationRequest else {
            throw VideoProcessingError.modelLoadError
        }

        let asset = AVAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        var results: [ClassificationResult] = []
        var frameNumber = 0

        let frameDuration = CMTimeMake(value: 1, timescale: Int32(frameInterval))
        var currentTime = CMTime.zero

        while currentTime < asset.duration {
            do {
                let imageRef = try generator.copyCGImage(at: currentTime, actualTime: nil)
                let requestHandler = VNImageRequestHandler(cgImage: imageRef)
                try requestHandler.perform([request])

                if let observations = request.results as? [VNClassificationObservation] {
                    let frameResults = observations.prefix(3).map { observation in
                        ClassificationResult(
                            timestamp: CMTimeGetSeconds(currentTime),
                            label: observation.identifier,
                            confidence: observation.confidence,
                        )
                    }
                    results.append(contentsOf: frameResults)
                }

                currentTime = CMTimeAdd(currentTime, frameDuration)
                frameNumber += 1
            } catch {
                throw VideoProcessingError.processingError("Error processing frame \(frameNumber)")
            }
        }

        return results
    }
}
