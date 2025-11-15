import Foundation

/// C2PA Manifest structure for content provenance
public struct C2PAManifest: Codable, Sendable {
    public let claimGenerator: String
    public let title: String
    public let format: String
    public let instanceID: String
    public let assertions: [Assertion]
    public let ingredients: [Ingredient]?

    public init(
        title: String,
        format: String,
        instanceID: String = UUID().uuidString,
        assertions: [Assertion] = [],
        ingredients: [Ingredient]? = nil
    ) {
        self.claimGenerator = "Arkavo Creator/1.0.0"
        self.title = title
        self.format = format
        self.instanceID = instanceID
        self.assertions = assertions
        self.ingredients = ingredients
    }

    enum CodingKeys: String, CodingKey {
        case claimGenerator = "claim_generator"
        case title
        case format
        case instanceID = "instance_id"
        case assertions
        case ingredients
    }
}

/// C2PA Assertion
public struct Assertion: Codable, Sendable {
    public let label: String
    public let data: AssertionData

    public init(label: String, data: AssertionData) {
        self.label = label
        self.data = data
    }
}

/// Assertion data types
public enum AssertionData: Codable, Sendable {
    case actions(Actions)
    case creativeWork(CreativeWork)
    case metadata(Metadata)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .actions(let actions):
            try container.encode(actions)
        case .creativeWork(let work):
            try container.encode(work)
        case .metadata(let metadata):
            try container.encode(metadata)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let actions = try? container.decode(Actions.self) {
            self = .actions(actions)
        } else if let work = try? container.decode(CreativeWork.self) {
            self = .creativeWork(work)
        } else if let metadata = try? container.decode(Metadata.self) {
            self = .metadata(metadata)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown assertion data type"
            )
        }
    }
}

/// Actions performed on the content
public struct Actions: Codable, Sendable {
    public let actions: [Action]

    public init(actions: [Action]) {
        self.actions = actions
    }
}

/// Individual action
public struct Action: Codable, Sendable {
    public let action: String
    public let when: String
    public let softwareAgent: String
    public let parameters: [String: String]?

    public init(
        action: String,
        when: Date = Date(),
        softwareAgent: String = "Arkavo Creator/1.0.0",
        parameters: [String: String]? = nil
    ) {
        self.action = action
        self.when = ISO8601DateFormatter().string(from: when)
        self.softwareAgent = softwareAgent
        self.parameters = parameters
    }

    enum CodingKeys: String, CodingKey {
        case action
        case when
        case softwareAgent = "softwareAgent"
        case parameters
    }
}

/// Creative work metadata
public struct CreativeWork: Codable, Sendable {
    public let author: [Author]?

    public init(author: [Author]?) {
        self.author = author
    }
}

/// Author information
public struct Author: Codable, Sendable {
    public let name: String
    public let identifier: String?

    public init(name: String, identifier: String? = nil) {
        self.name = name
        self.identifier = identifier
    }
}

/// Generic metadata
public struct Metadata: Codable, Sendable {
    public let values: [String: String]

    public init(values: [String: String]) {
        self.values = values
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.values = try container.decode([String: String].self)
    }
}

/// Ingredient (parent/source content)
public struct Ingredient: Codable, Sendable {
    public let title: String
    public let format: String
    public let instanceID: String
    public let relationship: String

    public init(
        title: String,
        format: String,
        instanceID: String,
        relationship: String = "parentOf"
    ) {
        self.title = title
        self.format = format
        self.instanceID = instanceID
        self.relationship = relationship
    }

    enum CodingKeys: String, CodingKey {
        case title
        case format
        case instanceID = "instance_id"
        case relationship
    }
}

// MARK: - Manifest Builder

public struct C2PAManifestBuilder {
    private var title: String
    private var format: String
    private var assertions: [Assertion] = []
    private var ingredients: [Ingredient]? = nil

    public init(title: String, format: String = "video/quicktime") {
        self.title = title
        self.format = format
    }

    public mutating func addCreatedAction(when: Date = Date()) -> Self {
        let action = Action(
            action: "c2pa.created",
            when: when,
            parameters: ["app": "Arkavo Creator", "version": "1.0.0"]
        )
        assertions.append(Assertion(
            label: "c2pa.actions",
            data: .actions(Actions(actions: [action]))
        ))
        return self
    }

    public mutating func addRecordedAction(when: Date = Date(), duration: TimeInterval) -> Self {
        let action = Action(
            action: "c2pa.recorded",
            when: when,
            parameters: [
                "duration": String(format: "%.2f", duration),
                "codec": "H.264",
                "resolution": "1920x1080",
                "framerate": "30"
            ]
        )
        assertions.append(Assertion(
            label: "c2pa.actions",
            data: .actions(Actions(actions: [action]))
        ))
        return self
    }

    public mutating func addAuthor(name: String, identifier: String? = nil) -> Self {
        let author = Author(name: name, identifier: identifier)
        assertions.append(Assertion(
            label: "stds.schema-org.CreativeWork",
            data: .creativeWork(CreativeWork(author: [author]))
        ))
        return self
    }

    public mutating func addDeviceMetadata(model: String, os: String) -> Self {
        assertions.append(Assertion(
            label: "arkavo.device",
            data: .metadata(Metadata(values: [
                "model": model,
                "os": os,
                "platform": "macOS"
            ]))
        ))
        return self
    }

    public mutating func addIngredient(_ ingredient: Ingredient) -> Self {
        if ingredients == nil {
            ingredients = []
        }
        ingredients?.append(ingredient)
        return self
    }

    public func build() -> C2PAManifest {
        return C2PAManifest(
            title: title,
            format: format,
            assertions: assertions,
            ingredients: ingredients
        )
    }
}
