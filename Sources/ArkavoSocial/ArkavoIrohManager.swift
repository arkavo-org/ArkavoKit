import Foundation
import IrohSwift
#if canImport(Observation)
import Observation
#endif

// MARK: - ArkavoIrohConfig

/// Configuration for the Arkavo iroh integration
public struct ArkavoIrohConfig: Sendable {
    /// Custom storage path (defaults to Application Support/arkavo-iroh)
    public var storagePath: URL?
    /// Enable relay servers for NAT traversal (default: true)
    public var relayEnabled: Bool

    public init(
        storagePath: URL? = nil,
        relayEnabled: Bool = true
    ) {
        self.storagePath = storagePath
        self.relayEnabled = relayEnabled
    }

    /// Default configuration
    public static let `default` = ArkavoIrohConfig()

    /// Convert to IrohConfig
    func toIrohConfig() -> IrohConfig {
        if let storagePath {
            return IrohConfig(storagePath: storagePath, relayEnabled: relayEnabled)
        } else {
            // Use default storage with custom subdirectory for Arkavo
            let defaultPath = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("arkavo-iroh", isDirectory: true)
            return IrohConfig(storagePath: defaultPath, relayEnabled: relayEnabled)
        }
    }
}

// MARK: - ArkavoIrohManager

/// Singleton manager for the Arkavo iroh integration
///
/// Manages the lifecycle of the IrohNode and provides access to services.
///
/// Usage:
/// ```swift
/// // Initialize at app startup
/// await ArkavoIrohManager.shared.initialize()
///
/// // Access the profile service
/// if let service = await ArkavoIrohManager.shared.profileService {
///     let ticket = try await service.publishProfile(profile)
/// }
/// ```
@Observable
public final class ArkavoIrohManager: Sendable {
    /// Shared singleton instance
    public static let shared = ArkavoIrohManager()

    /// The underlying node manager
    @MainActor
    private var nodeManager: IrohNodeManager?

    /// The profile service (created when node is ready)
    @MainActor
    private var _profileService: IrohProfileService?

    /// Whether the manager is currently initializing
    @MainActor
    public private(set) var isInitializing: Bool = false

    /// Any error that occurred during initialization
    @MainActor
    public private(set) var error: (any Error)?

    /// The configuration used for initialization
    @MainActor
    private var config: ArkavoIrohConfig?

    private init() {}

    // MARK: - Initialization

    /// Initialize the iroh node with the given configuration
    ///
    /// Safe to call multiple times - subsequent calls are ignored if already initialized.
    ///
    /// - Parameter config: Configuration options
    @MainActor
    public func initialize(config: ArkavoIrohConfig = .default) async {
        guard nodeManager == nil, !isInitializing else { return }

        isInitializing = true
        error = nil
        self.config = config

        let manager = IrohNodeManager()
        nodeManager = manager

        await manager.initialize(config: config.toIrohConfig())

        if let node = manager.node {
            _profileService = IrohProfileService(node: node)
        } else if let managerError = manager.error {
            error = managerError
        }

        isInitializing = false
    }

    /// Reset the manager, destroying the node and services
    @MainActor
    public func reset() {
        nodeManager?.reset()
        nodeManager = nil
        _profileService = nil
        error = nil
        isInitializing = false
        config = nil
    }

    // MARK: - Accessors

    /// The initialized iroh node, if available
    @MainActor
    public var node: IrohNode? {
        nodeManager?.node
    }

    /// The profile service, if node is initialized
    @MainActor
    public var profileService: IrohProfileService? {
        _profileService
    }

    /// Whether the node is ready for use
    @MainActor
    public var isReady: Bool {
        nodeManager?.node != nil
    }

    /// Get node info (requires initialized node)
    @MainActor
    public func nodeInfo() async throws -> NodeInfo? {
        guard let node = nodeManager?.node else { return nil }
        return try await node.info()
    }
}
