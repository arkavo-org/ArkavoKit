import Foundation
import ArkavoSocial

/// Task offer from LocalAIAgent to Orchestrator when user triggers intent
public struct TaskOffer: Codable, Sendable {
    public let intentId: String
    public let capabilitiesHint: [String]?
    public let deviceCaps: DeviceCapabilities
    public let intent: String
    public let context: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case intentId = "intent_id"
        case capabilitiesHint = "capabilities_hint"
        case deviceCaps = "device_caps"
        case intent
        case context
    }

    public init(intentId: String, intent: String, deviceCaps: DeviceCapabilities, capabilitiesHint: [String]? = nil, context: AnyCodable? = nil) {
        self.intentId = intentId
        self.intent = intent
        self.deviceCaps = deviceCaps
        self.capabilitiesHint = capabilitiesHint
        self.context = context
    }
}

/// Device capabilities available on the local device
public struct DeviceCapabilities: Codable, Sendable {
    public let aiCapabilities: [AiCapability]
    public let sensors: [SensorType]
    public let platform: DevicePlatform
    public let osVersion: String

    enum CodingKeys: String, CodingKey {
        case aiCapabilities = "ai_capabilities"
        case sensors
        case platform
        case osVersion = "os_version"
    }

    public init(aiCapabilities: [AiCapability], sensors: [SensorType], platform: DevicePlatform, osVersion: String) {
        self.aiCapabilities = aiCapabilities
        self.sensors = sensors
        self.platform = platform
        self.osVersion = osVersion
    }
}

/// On-device AI capability
public enum AiCapability: String, Codable, Sendable {
    case foundationModels = "foundation_models"
    case writingTools = "writing_tools"
    case imagePlayground = "image_playground"
    case speechRecognition = "speech_recognition"
    case textToSpeech = "text_to_speech"
}

/// Device platform
public enum DevicePlatform: String, Codable, Sendable {
    case ios
    case macos
    case tvos
    case watchos
}

/// Type of sensor available on device
public enum SensorType: String, Codable, Sendable {
    case location
    case camera
    case microphone
    case motion
    case nearbyDevices = "nearby_devices"
    case compass
    case ambientLight = "ambient_light"
    case barometer
}

/// Request for sensor data from LocalAIAgent
public struct SensorRequest: Codable, Sendable {
    public let taskId: String
    public let sensor: SensorType
    public let scope: DataScope
    public let retention: UInt64?
    public let rate: Double?
    public let policyTag: String

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case sensor
        case scope
        case retention
        case rate
        case policyTag = "policy_tag"
    }

    public init(taskId: String, sensor: SensorType, scope: DataScope, policyTag: String, retention: UInt64? = nil, rate: Double? = nil) {
        self.taskId = taskId
        self.sensor = sensor
        self.scope = scope
        self.policyTag = policyTag
        self.retention = retention
        self.rate = rate
    }
}

/// Level of detail for sensor data
public enum DataScope: String, Codable, Sendable {
    case minimal
    case standard
    case detailed
}

/// Response with sensor data
public struct SensorResponse: Codable, Sendable {
    public let taskId: String
    public let payload: AnyCodable
    public let redactions: [String]
    public let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case payload
        case redactions
        case timestamp
    }

    public init(taskId: String, payload: AnyCodable, redactions: [String] = [], timestamp: Date = Date()) {
        self.taskId = taskId
        self.payload = payload
        self.redactions = redactions
        self.timestamp = timestamp
    }
}

/// Tool call with locality specification
public struct ToolCall: Codable, Sendable {
    public let toolCallId: String
    public let name: String
    public let args: AnyCodable
    public let locality: Locality

    enum CodingKeys: String, CodingKey {
        case toolCallId = "tool_call_id"
        case name
        case args
        case locality
    }

    public init(toolCallId: String, name: String, args: AnyCodable, locality: Locality) {
        self.toolCallId = toolCallId
        self.name = name
        self.args = args
        self.locality = locality
    }
}

/// Where a tool should execute
public enum Locality: String, Codable, Sendable {
    case local
    case remote
}

/// Tool call result
public struct ToolCallResult: Codable, Sendable {
    public let toolCallId: String
    public let success: Bool
    public let result: AnyCodable?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case toolCallId = "tool_call_id"
        case success
        case result
        case error
    }

    public init(toolCallId: String, success: Bool, result: AnyCodable? = nil, error: String? = nil) {
        self.toolCallId = toolCallId
        self.success = success
        self.result = result
        self.error = error
    }
}

/// Request for human assistance
public struct HumanAssistRequest: Codable, Sendable {
    public let agentId: String
    public let reason: String
    public let contextHandle: String
    public let suggestedQuestions: [String]?

    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case reason
        case contextHandle = "context_handle"
        case suggestedQuestions = "suggested_questions"
    }

    public init(agentId: String, reason: String, contextHandle: String, suggestedQuestions: [String]? = nil) {
        self.agentId = agentId
        self.reason = reason
        self.contextHandle = contextHandle
        self.suggestedQuestions = suggestedQuestions
    }
}

/// Task result with artifacts and citations
public struct TaskResult: Codable, Sendable {
    public let taskId: String
    public let artifacts: [Artifact]
    public let citations: [Citation]
    public let policyTag: String
    public let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case artifacts
        case citations
        case policyTag = "policy_tag"
        case timestamp
    }

    public init(taskId: String, artifacts: [Artifact], citations: [Citation] = [], policyTag: String, timestamp: Date = Date()) {
        self.taskId = taskId
        self.artifacts = artifacts
        self.citations = citations
        self.policyTag = policyTag
        self.timestamp = timestamp
    }
}

/// Result artifact
public struct Artifact: Codable, Sendable {
    public let artifactType: ArtifactType
    public let content: AnyCodable
    public let metadata: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case artifactType = "artifact_type"
        case content
        case metadata
    }

    public init(artifactType: ArtifactType, content: AnyCodable, metadata: AnyCodable? = nil) {
        self.artifactType = artifactType
        self.content = content
        self.metadata = metadata
    }
}

/// Type of artifact
public enum ArtifactType: String, Codable, Sendable {
    case text
    case image
    case audio
    case video
    case data
    case file
}

/// Citation for sources
public struct Citation: Codable, Sendable {
    public let source: String
    public let url: String?
    public let timestamp: Date?
    public let metadata: AnyCodable?

    public init(source: String, url: String? = nil, timestamp: Date? = nil, metadata: AnyCodable? = nil) {
        self.source = source
        self.url = url
        self.timestamp = timestamp
        self.metadata = metadata
    }
}
