import ArkavoSocial
import Foundation
#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Client for Apple Intelligence Foundation Models (iOS 26+)
/// Provides structured generation, streaming, and local tool calling
@MainActor
public final class AppleIntelligenceClient: ObservableObject {
    @Published public private(set) var isAvailable: Bool = false
    @Published public private(set) var lastError: String?

    #if canImport(FoundationModels)
    private var session: Any? // Stores LanguageModelSession, but using Any to avoid @available requirement
    #endif

    public init() {
        checkAvailability()
    }

    /// Check if Foundation Models are available on this device
    private func checkAvailability() {
        #if canImport(FoundationModels)
        #if os(iOS) || os(macOS)
            if #available(iOS 26.0, macOS 26.0, *) {
                // Check actual model availability
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

    /// Execute a tool call using Foundation Models
    public func executeToolCall(_ toolCall: ToolCall) async throws -> ToolCallResult {
        guard isAvailable else {
            throw AppleIntelligenceError.notAvailable
        }

        switch toolCall.name {
        case "foundation_models_generate":
            return try await generateText(toolCall)
        case "foundation_models_structured":
            return try await generateStructured(toolCall)
        default:
            throw AppleIntelligenceError.unknownTool(toolCall.name)
        }
    }

    /// Generate text using Foundation Models
    private func generateText(_ toolCall: ToolCall) async throws -> ToolCallResult {
        guard let args = toolCall.args.value as? [String: Any],
              let prompt = args["prompt"] as? String else {
            return ToolCallResult(
                toolCallId: toolCall.toolCallId,
                success: false,
                error: "Invalid arguments: 'prompt' is required"
            )
        }

        let maxTokens = args["max_tokens"] as? Int ?? 500
        let temperature = args["temperature"] as? Double ?? 0.7

        do {
            let response = try await performGeneration(
                prompt: prompt,
                maxTokens: maxTokens,
                temperature: temperature
            )

            return ToolCallResult(
                toolCallId: toolCall.toolCallId,
                success: true,
                result: AnyCodable(["text": response])
            )
        } catch {
            return ToolCallResult(
                toolCallId: toolCall.toolCallId,
                success: false,
                error: error.localizedDescription
            )
        }
    }

    /// Generate structured output using Foundation Models
    private func generateStructured(_ toolCall: ToolCall) async throws -> ToolCallResult {
        guard let args = toolCall.args.value as? [String: Any],
              let prompt = args["prompt"] as? String,
              let schema = args["schema"] as? [String: Any] else {
            return ToolCallResult(
                toolCallId: toolCall.toolCallId,
                success: false,
                error: "Invalid arguments: 'prompt' and 'schema' are required"
            )
        }

        do {
            let response = try await performStructuredGeneration(
                prompt: prompt,
                schema: schema
            )

            return ToolCallResult(
                toolCallId: toolCall.toolCallId,
                success: true,
                result: AnyCodable(response)
            )
        } catch {
            return ToolCallResult(
                toolCallId: toolCall.toolCallId,
                success: false,
                error: error.localizedDescription
            )
        }
    }

    /// Perform text generation with Foundation Models
    private func performGeneration(prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
        #if canImport(FoundationModels)
        #if os(iOS)
            if #available(iOS 26.0, *) {
                guard let session = session as? LanguageModelSession else {
                    throw AppleIntelligenceError.sessionError("Session not initialized")
                }

                // Note: Foundation Models API doesn't expose maxTokens or temperature directly
                // These are handled by the system model
                do {
                    let response = try await session.respond(to: prompt)
                    return response.content
                } catch {
                    throw AppleIntelligenceError.sessionError("Generation failed: \(error.localizedDescription)")
                }
            }
        #elseif os(macOS)
            if #available(macOS 26.0, *) {
                guard let session = session as? LanguageModelSession else {
                    throw AppleIntelligenceError.sessionError("Session not initialized")
                }

                do {
                    let response = try await session.respond(to: prompt)
                    return response.content
                } catch {
                    throw AppleIntelligenceError.sessionError("Generation failed: \(error.localizedDescription)")
                }
            }
        #endif
        #endif

        throw AppleIntelligenceError.notAvailable
    }

    /// Perform structured generation with Foundation Models
    /// Note: For true structured output with compile-time safety, define structs with @Generable macro
    /// This implementation uses text generation with schema prompting as fallback
    private func performStructuredGeneration(prompt: String, schema: [String: Any]) async throws -> [String: Any] {
        #if canImport(FoundationModels)
        #if os(iOS)
            if #available(iOS 26.0, *) {
                guard let session = session as? LanguageModelSession else {
                    throw AppleIntelligenceError.sessionError("Session not initialized")
                }

                // Convert schema to JSON string for prompt augmentation
                let schemaData = try JSONSerialization.data(withJSONObject: schema)
                let schemaString = String(data: schemaData, encoding: .utf8) ?? "{}"

                let structuredPrompt = """
                \(prompt)

                Please respond with valid JSON matching this schema:
                \(schemaString)

                Respond only with the JSON object, no additional text.
                """

                do {
                    let response = try await session.respond(to: structuredPrompt)
                    let responseText = response.content

                    // Parse JSON response
                    guard let responseData = responseText.data(using: .utf8),
                          let jsonObject = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                        throw AppleIntelligenceError.sessionError("Failed to parse structured response as JSON")
                    }

                    return jsonObject
                } catch {
                    throw AppleIntelligenceError.sessionError("Structured generation failed: \(error.localizedDescription)")
                }
            }
        #elseif os(macOS)
            if #available(macOS 26.0, *) {
                guard let session = session as? LanguageModelSession else {
                    throw AppleIntelligenceError.sessionError("Session not initialized")
                }

                let schemaData = try JSONSerialization.data(withJSONObject: schema)
                let schemaString = String(data: schemaData, encoding: .utf8) ?? "{}"

                let structuredPrompt = """
                \(prompt)

                Please respond with valid JSON matching this schema:
                \(schemaString)

                Respond only with the JSON object, no additional text.
                """

                do {
                    let response = try await session.respond(to: structuredPrompt)
                    let responseText = response.content

                    guard let responseData = responseText.data(using: .utf8),
                          let jsonObject = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                        throw AppleIntelligenceError.sessionError("Failed to parse structured response as JSON")
                    }

                    return jsonObject
                } catch {
                    throw AppleIntelligenceError.sessionError("Structured generation failed: \(error.localizedDescription)")
                }
            }
        #endif
        #endif

        throw AppleIntelligenceError.notAvailable
    }

    /// Stream text generation
    /// Note: Foundation Models API may not expose true streaming yet
    /// This implementation simulates streaming by chunking the response
    public func streamGeneration(prompt: String, onDelta: @escaping (String) -> Void) async throws {
        guard isAvailable else {
            throw AppleIntelligenceError.notAvailable
        }

        #if canImport(FoundationModels)
        #if os(iOS)
            if #available(iOS 26.0, *) {
                guard let session = session as? LanguageModelSession else {
                    throw AppleIntelligenceError.sessionError("Session not initialized")
                }

                do {
                    // Get full response
                    let response = try await session.respond(to: prompt)
                    let responseText = response.content

                    // Simulate streaming by chunking the response
                    // This provides a better UX than waiting for the full response
                    let chunkSize = 20 // characters per chunk
                    var startIndex = responseText.startIndex

                    while startIndex < responseText.endIndex {
                        let endIndex = responseText.index(startIndex, offsetBy: chunkSize, limitedBy: responseText.endIndex) ?? responseText.endIndex
                        let chunk = String(responseText[startIndex..<endIndex])
                        onDelta(chunk)

                        // Small delay to simulate streaming
                        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

                        startIndex = endIndex
                    }
                } catch {
                    throw AppleIntelligenceError.sessionError("Streaming generation failed: \(error.localizedDescription)")
                }
            }
        #elseif os(macOS)
            if #available(macOS 26.0, *) {
                guard let session = session as? LanguageModelSession else {
                    throw AppleIntelligenceError.sessionError("Session not initialized")
                }

                do {
                    let response = try await session.respond(to: prompt)
                    let responseText = response.content

                    let chunkSize = 20
                    var startIndex = responseText.startIndex

                    while startIndex < responseText.endIndex {
                        let endIndex = responseText.index(startIndex, offsetBy: chunkSize, limitedBy: responseText.endIndex) ?? responseText.endIndex
                        let chunk = String(responseText[startIndex..<endIndex])
                        onDelta(chunk)

                        try await Task.sleep(nanoseconds: 50_000_000)

                        startIndex = endIndex
                    }
                } catch {
                    throw AppleIntelligenceError.sessionError("Streaming generation failed: \(error.localizedDescription)")
                }
            }
        #endif
        #endif

        throw AppleIntelligenceError.notAvailable
    }

    /// Call a local tool from within Foundation Models
    /// Note: Foundation Models API tool calling uses the @ToolProvider macro
    /// This is a future enhancement for dynamic tool registration
    public func callLocalTool(name: String, args: [String: Any]) async throws -> [String: Any] {
        throw AppleIntelligenceError.notImplemented("Dynamic tool calling pending - use @ToolProvider macro for compile-time tool definition")
    }
}

public enum AppleIntelligenceError: Error, LocalizedError {
    case notAvailable
    case notImplemented(String)
    case unknownTool(String)
    case sessionError(String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Foundation Models not available on this device (requires iOS 26+ or macOS 26+)"
        case .notImplemented(let detail):
            return "Feature not yet implemented: \(detail)"
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .sessionError(let detail):
            return "Session error: \(detail)"
        }
    }
}

/// Available Foundation Models tools
public enum FoundationModelsTool {
    /// Generate text from a prompt
    case generate(prompt: String, maxTokens: Int, temperature: Double)

    /// Generate structured output conforming to a schema
    case structured(prompt: String, schema: [String: Any])

    /// Call a local device tool
    case callTool(name: String, args: [String: Any])

    public var name: String {
        switch self {
        case .generate:
            return "foundation_models_generate"
        case .structured:
            return "foundation_models_structured"
        case .callTool:
            return "foundation_models_call_tool"
        }
    }

    public var args: [String: Any] {
        switch self {
        case .generate(let prompt, let maxTokens, let temperature):
            return [
                "prompt": prompt,
                "max_tokens": maxTokens,
                "temperature": temperature,
            ]
        case .structured(let prompt, let schema):
            return [
                "prompt": prompt,
                "schema": schema,
            ]
        case .callTool(let name, let args):
            return [
                "tool_name": name,
                "tool_args": args,
            ]
        }
    }
}
