import Foundation
import os

/// Result of waiting for capture sources to become ready
public enum CaptureReadinessResult: Sendable {
    case allReady
    case partialReady(failed: [String: String])

    public var isAllReady: Bool {
        if case .allReady = self { return true }
        return false
    }
}

/// A registered capture source with its start function
public struct RegisteredSource: Sendable {
    public let sourceID: String
    public let sourceType: CaptureSourceType
    /// Async function to start capture and wait for first frame
    public let start: @Sendable () async throws -> Void

    public init(
        sourceID: String,
        sourceType: CaptureSourceType,
        start: @escaping @Sendable () async throws -> Void
    ) {
        self.sourceID = sourceID
        self.sourceType = sourceType
        self.start = start
    }
}

/// Coordinates multiple capture sources and ensures all are ready before recording
public actor CaptureSourceRegistry {
    private var sources: [String: RegisteredSource] = [:]

    public init() { /* Actor requires explicit public initializer */ }

    /// Register a capture source with its startup function
    public func register(_ source: RegisteredSource) {
        sources[source.sourceID] = source
        print("📋 [CaptureSourceRegistry] Registered source '\(source.sourceID)' (\(source.sourceType))")
    }

    /// Unregister a capture source
    public func unregister(_ sourceID: String) {
        sources.removeValue(forKey: sourceID)
        print("📋 [CaptureSourceRegistry] Unregistered source '\(sourceID)'")
    }

    /// Clear all registered sources
    public func clear() {
        sources.removeAll()
    }

    /// Get count of registered sources
    public var sourceCount: Int {
        sources.count
    }

    /// Start all registered sources and wait for all to be ready
    /// - Parameter timeout: Maximum time to wait for all sources (default 5 seconds)
    /// - Returns: Result indicating success or which sources failed
    public func startAllAndWaitForReady(timeout: TimeInterval = 5.0) async -> CaptureReadinessResult {
        let startTime = Date()
        var failedSources: [String: String] = [:]
        var successSources: [String] = []

        print("⏳ [CaptureSourceRegistry] Starting \(sources.count) capture source(s)...")

        // Start all sources concurrently with timeout
        await withTaskGroup(of: (String, Result<Void, Error>).self) { group in
            for (id, source) in sources {
                group.addTask {
                    do {
                        try await Self.start(source, timeout: timeout)
                        return (id, .success(()))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }

            for await (id, result) in group {
                switch result {
                case .success:
                    successSources.append(id)
                    print("✅ [CaptureSourceRegistry] Source '\(id)' ready")
                case let .failure(error):
                    failedSources[id] = error.localizedDescription
                    print("❌ [CaptureSourceRegistry] Source '\(id)' failed: \(error.localizedDescription)")
                }
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)

        if failedSources.isEmpty {
            print("✅ [CaptureSourceRegistry] All \(sources.count) sources ready in \(String(format: "%.2f", elapsed))s")
            return .allReady
        } else {
            print("⚠️ [CaptureSourceRegistry] \(successSources.count)/\(sources.count) sources ready, \(failedSources.count) failed")
            return .partialReady(failed: failedSources)
        }
    }

    /// Starts `source`, giving up after `timeout`. The start runs in its own task, so a
    /// first-frame wait that ignores cancellation (e.g. a camera that never delivers a
    /// frame) is cancelled and left behind instead of holding up recording startup.
    /// Whichever of the start and the timeout finishes first cancels the other.
    private static func start(_ source: RegisteredSource, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let state = OSAllocatedUnfairLock(
                initialState: (continuation: Optional(continuation), tasks: [Task<Void, Never>]())
            )
            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                let (pending, tasks) = state.withLock { state in
                    defer { state = (nil, []) }
                    return (state.continuation, state.tasks)
                }
                tasks.forEach { $0.cancel() }
                pending?.resume(with: result)
            }
            let track: @Sendable (Task<Void, Never>) -> Void = { task in
                let finished = state.withLock { state in
                    if state.continuation == nil { return true }
                    state.tasks.append(task)
                    return false
                }
                if finished { task.cancel() }
            }
            track(Task {
                do {
                    try await source.start()
                    finish(.success(()))
                } catch {
                    finish(.failure(error))
                }
            })
            track(Task {
                try? await Task.sleep(for: .seconds(timeout))
                finish(.failure(CaptureSourceError.timeout(sourceID: source.sourceID, after: timeout)))
            })
        }
    }
}
