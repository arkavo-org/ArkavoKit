import Dispatch

/// Runs `read` with its jobs on GCD threads, not the cooperative pool. Tests read media files
/// through this.
///
/// `AVAssetReaderOutput.Provider.next()` blocks the thread it runs on until the reader has a
/// buffer, and the reader needs a cooperative-pool thread to make one. On the pool, as many reads
/// at once as the pool has threads all wait and none finishes: on CI's 3-CPU runner, three tests
/// reading at the same moment hung the run (AssetReadingTests). While the pool's threads wait,
/// GCD's global queues get no new thread either, so each read gets a serial queue of its own,
/// which does. `read` must be nonisolated, so that `next()` runs where it does.
func readingOffThePool<T, Failure: Error>(_ read: () async throws(Failure) -> T) async throws(Failure) -> T {
    try await withTaskExecutorPreference(DispatchQueue(label: "com.arkavo.tests.asset-reading"), operation: read)
}
