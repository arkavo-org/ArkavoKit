import ArkavoSocial
import Foundation
#if os(iOS)
    import UIKit
    #if canImport(FoundationModels)
        import FoundationModels
    #endif
#elseif os(macOS)
    import AppKit
    #if canImport(FoundationModels)
        import FoundationModels
    #endif
#endif

/// Integration with Apple Writing Tools (iOS 26+, macOS 26+)
/// Provides text refinement, proofreading, summarization using Foundation Models
/// Note: System-wide Writing Tools in text fields are automatic and don't require API integration
@MainActor
public final class WritingToolsIntegration: ObservableObject {
    @Published public private(set) var isAvailable: Bool = false
    @Published public private(set) var lastError: String?

    #if canImport(FoundationModels)
    private var session: Any? // Stores LanguageModelSession, but using Any to avoid @available requirement
    #endif

    public init() {
        checkAvailability()
    }

    /// Check if Writing Tools are available on this device
    private func checkAvailability() {
        #if canImport(FoundationModels)
        #if os(iOS) || os(macOS)
            if #available(iOS 26.0, macOS 26.0, *) {
                // Check Foundation Models availability (powers Writing Tools features)
                if case .available = SystemLanguageModel.default.availability {
                    isAvailable = true
                    session = LanguageModelSession()
                } else {
                    isAvailable = false
                }
            } else {
                isAvailable = false
            }
        #else
            isAvailable = false
        #endif
        #else
            isAvailable = false
        #endif
    }

    /// Execute a tool call using Writing Tools
    public func executeToolCall(_ toolCall: ToolCall) async throws -> ToolCallResult {
        guard isAvailable else {
            throw WritingToolsError.notAvailable
        }

        switch toolCall.name {
        case "writing_tools_proofread":
            return try await proofread(toolCall)
        case "writing_tools_rewrite":
            return try await rewrite(toolCall)
        case "writing_tools_summarize":
            return try await summarize(toolCall)
        default:
            throw WritingToolsError.unknownTool(toolCall.name)
        }
    }

    /// Proofread text using Writing Tools
    private func proofread(_ toolCall: ToolCall) async throws -> ToolCallResult {
        guard let args = toolCall.args.value as? [String: Any],
              let text = args["text"] as? String else {
            return ToolCallResult(
                toolCallId: toolCall.toolCallId,
                success: false,
                error: "Invalid arguments: 'text' is required"
            )
        }

        do {
            let proofreadText = try await performProofread(text: text)

            return ToolCallResult(
                toolCallId: toolCall.toolCallId,
                success: true,
                result: AnyCodable([
                    "text": proofreadText.correctedText,
                    "corrections": proofreadText.corrections,
                ])
            )
        } catch {
            return ToolCallResult(
                toolCallId: toolCall.toolCallId,
                success: false,
                error: error.localizedDescription
            )
        }
    }

    /// Rewrite text using Writing Tools
    private func rewrite(_ toolCall: ToolCall) async throws -> ToolCallResult {
        guard let args = toolCall.args.value as? [String: Any],
              let text = args["text"] as? String else {
            return ToolCallResult(
                toolCallId: toolCall.toolCallId,
                success: false,
                error: "Invalid arguments: 'text' is required"
            )
        }

        let tone = args["tone"] as? String ?? "professional"

        do {
            let rewrittenText = try await performRewrite(text: text, tone: tone)

            return ToolCallResult(
                toolCallId: toolCall.toolCallId,
                success: true,
                result: AnyCodable(["text": rewrittenText])
            )
        } catch {
            return ToolCallResult(
                toolCallId: toolCall.toolCallId,
                success: false,
                error: error.localizedDescription
            )
        }
    }

    /// Summarize text using Writing Tools
    private func summarize(_ toolCall: ToolCall) async throws -> ToolCallResult {
        guard let args = toolCall.args.value as? [String: Any],
              let text = args["text"] as? String else {
            return ToolCallResult(
                toolCallId: toolCall.toolCallId,
                success: false,
                error: "Invalid arguments: 'text' is required"
            )
        }

        let length = args["length"] as? String ?? "medium"

        do {
            let summary = try await performSummarize(text: text, length: length)

            return ToolCallResult(
                toolCallId: toolCall.toolCallId,
                success: true,
                result: AnyCodable(["summary": summary])
            )
        } catch {
            return ToolCallResult(
                toolCallId: toolCall.toolCallId,
                success: false,
                error: error.localizedDescription
            )
        }
    }

    /// Perform proofreading using Foundation Models
    private func performProofread(text: String) async throws -> ProofreadResult {
        #if canImport(FoundationModels)
        #if os(iOS)
            if #available(iOS 26.0, *) {
                guard let session = session as? LanguageModelSession else {
                    throw WritingToolsError.notAvailable
                }

                let prompt = """
                Proofread the following text and correct any grammar, spelling, or punctuation errors.
                Provide the corrected text and list all corrections made.

                Text to proofread:
                \(text)

                Respond with JSON in this format:
                {
                    "corrected_text": "the corrected version",
                    "corrections": [
                        {"type": "grammar", "original": "...", "corrected": "...", "position": 0}
                    ]
                }
                """

                do {
                    let response = try await session.respond(to: prompt)
                    let responseText = response.content

                    // Parse JSON response
                    guard let responseData = responseText.data(using: .utf8),
                          let jsonObject = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                          let correctedText = jsonObject["corrected_text"] as? String,
                          let corrections = jsonObject["corrections"] as? [[String: Any]] else {
                        // Fallback: if parsing fails, return original text with no corrections
                        return ProofreadResult(correctedText: text, corrections: [])
                    }

                    return ProofreadResult(correctedText: correctedText, corrections: corrections)
                } catch {
                    throw WritingToolsError.notAvailable
                }
            }
        #elseif os(macOS)
            if #available(macOS 26.0, *) {
                guard let session = session as? LanguageModelSession else {
                    throw WritingToolsError.notAvailable
                }

                let prompt = """
                Proofread the following text and correct any grammar, spelling, or punctuation errors.
                Provide the corrected text and list all corrections made.

                Text to proofread:
                \(text)

                Respond with JSON in this format:
                {
                    "corrected_text": "the corrected version",
                    "corrections": [
                        {"type": "grammar", "original": "...", "corrected": "...", "position": 0}
                    ]
                }
                """

                do {
                    let response = try await session.respond(to: prompt)
                    let responseText = response.content

                    guard let responseData = responseText.data(using: .utf8),
                          let jsonObject = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                          let correctedText = jsonObject["corrected_text"] as? String,
                          let corrections = jsonObject["corrections"] as? [[String: Any]] else {
                        return ProofreadResult(correctedText: text, corrections: [])
                    }

                    return ProofreadResult(correctedText: correctedText, corrections: corrections)
                } catch {
                    throw WritingToolsError.notAvailable
                }
            }
        #endif
        #endif

        throw WritingToolsError.notAvailable
    }

    /// Perform text rewriting using Foundation Models
    private func performRewrite(text: String, tone: String) async throws -> String {
        #if canImport(FoundationModels)
        #if os(iOS)
            if #available(iOS 26.0, *) {
                guard let session = session as? LanguageModelSession else {
                    throw WritingToolsError.notAvailable
                }

                let prompt = """
                Rewrite the following text in a \(tone) tone while preserving the core meaning and intent.

                Original text:
                \(text)

                Respond with only the rewritten text, no additional commentary.
                """

                do {
                    let response = try await session.respond(to: prompt)
                    return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    throw WritingToolsError.notAvailable
                }
            }
        #elseif os(macOS)
            if #available(macOS 26.0, *) {
                guard let session = session as? LanguageModelSession else {
                    throw WritingToolsError.notAvailable
                }

                let prompt = """
                Rewrite the following text in a \(tone) tone while preserving the core meaning and intent.

                Original text:
                \(text)

                Respond with only the rewritten text, no additional commentary.
                """

                do {
                    let response = try await session.respond(to: prompt)
                    return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    throw WritingToolsError.notAvailable
                }
            }
        #endif
        #endif

        throw WritingToolsError.notAvailable
    }

    /// Perform text summarization using Foundation Models
    private func performSummarize(text: String, length: String) async throws -> String {
        #if canImport(FoundationModels)
        #if os(iOS)
            if #available(iOS 26.0, *) {
                guard let session = session as? LanguageModelSession else {
                    throw WritingToolsError.notAvailable
                }

                // Map length parameter to specific instructions
                let lengthInstruction: String
                switch length.lowercased() {
                case "short":
                    lengthInstruction = "in 1-2 sentences"
                case "medium":
                    lengthInstruction = "in 3-4 sentences"
                case "long":
                    lengthInstruction = "in 1-2 paragraphs"
                default:
                    lengthInstruction = "concisely"
                }

                let prompt = """
                Summarize the following text \(lengthInstruction). Capture the key points and main ideas.

                Text to summarize:
                \(text)

                Respond with only the summary, no additional commentary.
                """

                do {
                    let response = try await session.respond(to: prompt)
                    return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    throw WritingToolsError.notAvailable
                }
            }
        #elseif os(macOS)
            if #available(macOS 26.0, *) {
                guard let session = session as? LanguageModelSession else {
                    throw WritingToolsError.notAvailable
                }

                let lengthInstruction: String
                switch length.lowercased() {
                case "short":
                    lengthInstruction = "in 1-2 sentences"
                case "medium":
                    lengthInstruction = "in 3-4 sentences"
                case "long":
                    lengthInstruction = "in 1-2 paragraphs"
                default:
                    lengthInstruction = "concisely"
                }

                let prompt = """
                Summarize the following text \(lengthInstruction). Capture the key points and main ideas.

                Text to summarize:
                \(text)

                Respond with only the summary, no additional commentary.
                """

                do {
                    let response = try await session.respond(to: prompt)
                    return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    throw WritingToolsError.notAvailable
                }
            }
        #endif
        #endif

        throw WritingToolsError.notAvailable
    }
}

/// Result of proofreading operation
public struct ProofreadResult {
    public let correctedText: String
    public let corrections: [[String: Any]]

    public init(correctedText: String, corrections: [[String: Any]]) {
        self.correctedText = correctedText
        self.corrections = corrections
    }
}

public enum WritingToolsError: Error, LocalizedError {
    case notAvailable
    case notImplemented(String)
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Writing Tools not available on this device (requires iOS 26+ or macOS 26+)"
        case .notImplemented(let detail):
            return "Feature not yet implemented: \(detail)"
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        }
    }
}

/// Available Writing Tools
public enum WritingTool {
    /// Proofread text for grammar and spelling
    case proofread(text: String)

    /// Rewrite text with a specific tone
    case rewrite(text: String, tone: String)

    /// Summarize text to a specific length
    case summarize(text: String, length: String)

    public var name: String {
        switch self {
        case .proofread:
            return "writing_tools_proofread"
        case .rewrite:
            return "writing_tools_rewrite"
        case .summarize:
            return "writing_tools_summarize"
        }
    }

    public var args: [String: Any] {
        switch self {
        case .proofread(let text):
            return ["text": text]
        case .rewrite(let text, let tone):
            return ["text": text, "tone": tone]
        case .summarize(let text, let length):
            return ["text": text, "length": length]
        }
    }
}
