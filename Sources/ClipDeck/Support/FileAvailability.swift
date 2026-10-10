import Foundation

/// Checks that files still exist before restoring references to them.
///
/// `fileExists` can stall for a long time on an unresponsive network volume, so
/// the checks run on a background thread and the caller waits only briefly.
/// Anything not confirmed in time is reported as unavailable rather than
/// risking a frozen interface.
enum FileAvailability {
    struct Result: Equatable {
        /// Indexes of files that are missing or could not be confirmed in time.
        let unavailableIndexes: [Int]
        let timedOut: Bool
    }

    static func check(_ urls: [URL], timeout: TimeInterval = 1.5) -> Result {
        guard !urls.isEmpty else { return Result(unavailableIndexes: [], timedOut: false) }
        let progress = Progress()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            for (index, url) in urls.enumerated() {
                let exists = FileManager.default.fileExists(atPath: url.path)
                progress.record(index: index, exists: exists)
            }
            finished.signal()
        }
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        let (checkedCount, missing) = progress.snapshot()
        let unchecked = timedOut ? Array(checkedCount..<urls.count) : []
        return Result(unavailableIndexes: missing + unchecked, timedOut: timedOut && !unchecked.isEmpty)
    }

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var checkedCount = 0
        private var missing: [Int] = []

        func record(index: Int, exists: Bool) {
            lock.withLock {
                if !exists { missing.append(index) }
                checkedCount = index + 1
            }
        }

        func snapshot() -> (Int, [Int]) {
            lock.withLock { (checkedCount, missing) }
        }
    }
}
