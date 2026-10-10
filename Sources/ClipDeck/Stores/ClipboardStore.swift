import AppKit
import Combine
import Foundation

@MainActor
private final class ClipboardUndoAction: NSObject {
    enum Operation {
        case restore
        case delete
    }

    let operation: Operation
    let item: ClipboardItem
    weak var undoManager: UndoManager?
    weak var store: ClipboardStore?

    init(
        operation: Operation,
        item: ClipboardItem,
        undoManager: UndoManager,
        store: ClipboardStore
    ) {
        self.operation = operation
        self.item = item
        self.undoManager = undoManager
        self.store = store
    }

    @objc func applyHistoryUndo(_ sender: Any?) { store?.performHistoryUndo(self) }
}

/// Where a capture warning belongs. Event-wide problems sort before per-item
/// notes, so the most important message is the one shown first.
private enum CaptureWarningSlot: Hashable, Comparable {
    case memoryBudget
    case readFailure
    case fileCountLimit
    case item(Int)

    private var order: Int {
        switch self {
        case .memoryBudget: return -3
        case .readFailure: return -2
        case .fileCountLimit: return -1
        case .item(let index): return index
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

@MainActor
private final class ClipboardCaptureEvent {
    var id = UUID()
    let changeCount: Int
    let capturedAt = Date.now
    let epoch: Int
    let sequence: Int
    var parts: [Int: ClipboardItem.Content] = [:]
    var originals: [Int: ClipboardRepresentationItem] = [:]
    var warnings: [CaptureWarningSlot: String] = [:]
    var imageSignatures: [Int: Data] = [:]
    var pendingImageIndexes = Set<Int>()
    var isFilesOnly = false
    var isDeleted = false

    init(changeCount: Int, epoch: Int, sequence: Int) {
        self.changeCount = changeCount
        self.epoch = epoch
        self.sequence = sequence
    }

    /// Every warning, most important first.
    var orderedWarnings: [String] {
        warnings.sorted { $0.key < $1.key }.map(\.value)
    }
}

private enum ClipboardReadFailureKind {
    case files
    case image
    case text

    var retryMessage: String {
        switch self {
        case .files:
            return L10n.string("检测到文件，但暂时无法读取；将自动重试。")
        case .image:
            return L10n.string("检测到图片，但暂时无法读取；将自动重试。")
        case .text:
            return L10n.string("检测到文字，但暂时无法读取；将自动重试。")
        }
    }

    var finalMessage: String {
        switch self {
        case .files:
            return L10n.string("文件连续多次读取失败，本次未记录。")
        case .image:
            return L10n.string("图片连续多次读取失败，本次未记录。")
        case .text:
            return L10n.string("文字连续多次读取失败，本次未记录。")
        }
    }
}

/// In-memory clipboard history for the current app session only.
@MainActor
final class ClipboardStore: NSObject, ObservableObject {
    struct Configuration: Sendable {
        var maximumItemCount: Int
        var maximumTextBytes: Int
        var maximumFileReferenceCount: Int
        var maximumImageHistoryBytes: Int
        var pollingInterval: TimeInterval
        var pollingTolerance: TimeInterval
        var maximumReadRetryAttempts: Int
        var maximumPendingImageCaptures: Int
        var maximumPendingImageCaptureBytes: Int
        var maximumImageSnapshotBytes: Int
        var maximumPasteboardRecoveryBytes: Int
        var maximumSnapshotCandidateCount: Int
        var maximumUndoItemCount: Int
        var maximumUndoBytes: Int

        init(
            maximumItemCount: Int = 40,
            maximumTextBytes: Int = 50_000,
            maximumFileReferenceCount: Int = 256,
            maximumImageHistoryBytes: Int = 128 * 1024 * 1024,
            pollingInterval: TimeInterval = 0.25,
            pollingTolerance: TimeInterval = 0.05,
            maximumReadRetryAttempts: Int = 3,
            maximumPendingImageCaptures: Int = 4,
            maximumPendingImageCaptureBytes: Int = 128 * 1024 * 1024,
            maximumImageSnapshotBytes: Int = 96 * 1024 * 1024,
            maximumPasteboardRecoveryBytes: Int = 64 * 1024 * 1024,
            maximumSnapshotCandidateCount: Int = 4,
            maximumUndoItemCount: Int = 20,
            maximumUndoBytes: Int = 64 * 1024 * 1024
        ) {
            self.maximumItemCount = max(1, maximumItemCount)
            self.maximumTextBytes = max(1, maximumTextBytes)
            self.maximumFileReferenceCount = max(1, maximumFileReferenceCount)
            self.maximumImageHistoryBytes = max(0, maximumImageHistoryBytes)
            self.pollingInterval = max(0.1, pollingInterval)
            self.pollingTolerance = max(0, pollingTolerance)
            self.maximumReadRetryAttempts = max(1, maximumReadRetryAttempts)
            self.maximumPendingImageCaptures = max(1, maximumPendingImageCaptures)
            self.maximumPendingImageCaptureBytes = max(1, maximumPendingImageCaptureBytes)
            self.maximumImageSnapshotBytes = max(1, maximumImageSnapshotBytes)
            self.maximumPasteboardRecoveryBytes = max(1, maximumPasteboardRecoveryBytes)
            self.maximumSnapshotCandidateCount = max(1, maximumSnapshotCandidateCount)
            self.maximumUndoItemCount = max(0, maximumUndoItemCount)
            self.maximumUndoBytes = max(0, maximumUndoBytes)
        }

        static let `default` = Configuration()
    }

    @Published private(set) var items: [ClipboardItem] = []
    @Published var isMonitoring: Bool {
        didSet {
            guard isMonitoring != oldValue else {
                return
            }

            userDefaults.set(isMonitoring, forKey: monitoringDefaultsKey)
            lastChangeCount = pasteboard.changeCount
            cancelPendingImageCaptures()
            captureEpoch += 1
            captureEvents.removeAll()
            resetReadRetryState()
            latestCaptureSequence += 1
            captureSequenceChangeCount = nil

            if isMonitoring {
                startMonitoring()
            } else {
                stopMonitoring()
            }

            setCaptureWarning(nil)
            refreshAccessStatus()
        }
    }
    @Published var isClearConfirmationPresented = false
    @Published private(set) var accessStatus: String?
    @Published private(set) var storageWarning: String?
    @Published private(set) var captureWarning: String?
    @Published private(set) var lastCopiedItemID: ClipboardItem.ID?
    private(set) var lastDeletionCanBeUndone = false

    /// The privacy policy consulted before each clipboard read.
    let privacySettings: CapturePrivacySettings

    private static let defaultMonitoringKey = "com.qiaoni.ClipDeck.isMonitoring"

    private let pasteboard: NSPasteboard
    private let userDefaults: UserDefaults
    private let monitoringDefaultsKey: String
    private let imageProcessor: any ImageProcessing
    private let configuration: Configuration
    private let frontmostApplicationIdentifier: @MainActor () -> String?

    private var lastChangeCount: Int
    // The timer is created and mutated on MainActor; unsafe isolation only lets
    // nonisolated deinit invalidate the RunLoop-owned reference.
    nonisolated(unsafe) private var pollTimer: Timer?
    private var captureTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingImageCaptureBytes = 0
    private var retryChangeCount: Int?
    private var readRetryAttemptCount = 0
    private var latestCaptureSequence = 0
    private var captureSequenceChangeCount: Int?
    private let snapshotReader = PasteboardSnapshotReader()
    private var snapshotTask: Task<Void, Never>?
    private var captureEpoch = 0
    private var captureEvents: [Int: ClipboardCaptureEvent] = [:]
    private var undoActions: [ClipboardUndoAction] = []

    init(
        pasteboard: NSPasteboard = .general,
        startsMonitoring: Bool = true,
        performsLegacyCleanup: Bool = true,
        userDefaults: UserDefaults = .standard,
        monitoringDefaultsKey: String = ClipboardStore.defaultMonitoringKey,
        imageProcessor: any ImageProcessing = ImageProcessor(),
        configuration: Configuration = .default,
        privacySettings: CapturePrivacySettings? = nil,
        frontmostApplicationIdentifier: @escaping @MainActor () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    ) {
        self.pasteboard = pasteboard
        self.userDefaults = userDefaults
        self.monitoringDefaultsKey = monitoringDefaultsKey
        self.imageProcessor = imageProcessor
        self.configuration = configuration
        self.privacySettings = privacySettings ?? CapturePrivacySettings(defaults: userDefaults)
        self.frontmostApplicationIdentifier = frontmostApplicationIdentifier
        self.lastChangeCount = pasteboard.changeCount
        self.isMonitoring = userDefaults.object(forKey: monitoringDefaultsKey) as? Bool ?? true
        self.accessStatus = nil
        self.storageWarning = nil
        self.captureWarning = nil
        self.lastCopiedItemID = nil
        super.init()

        if performsLegacyCleanup, !Self.removeLegacyStoredHistory() {
            storageWarning = L10n.string(
                "无法删除旧版本地历史；请退出应用后检查 Application Support/ClipDeck。"
            )
        }
        refreshAccessStatus()
        if startsMonitoring, isMonitoring {
            startMonitoring()
        }
    }

    func startMonitoring() {
        guard isMonitoring, pollTimer == nil else {
            return
        }

        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: configuration.pollingInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.requestPasteboardCapture()
            }
        }
        timer.tolerance = min(configuration.pollingTolerance, configuration.pollingInterval)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Whitespace-separated terms must all match, in any order.
    func filteredItems(matching query: String) -> [ClipboardItem] {
        ClipboardSearchQuery(query).filter(items)
    }

    @discardableResult
    func copy(_ item: ClipboardItem, plainTextOnly: Bool = false) -> Bool {
        latestCaptureSequence += 1
        captureSequenceChangeCount = nil

        if !plainTextOnly, let warning = unavailableFilesWarning(for: item) {
            setCaptureWarning(warning)
            return false
        }

        // Monitoring never writes to the pasteboard. An explicit restore is the
        // only mutation, and its complete payload is prepared before replacing
        // the user's current clipboard contents.
        let restoreToken = UUID().uuidString
        guard let pasteboardObjects = ClipboardRestorePayload.make(
            for: item,
            restoreToken: restoreToken,
            plainTextOnly: plainTextOnly
        ) else {
            setPreparationWarning(for: item)
            return false
        }
        let recoverySnapshot = PasteboardRecoverySnapshot.capture(
            from: pasteboard,
            maximumBytes: configuration.maximumPasteboardRecoveryBytes
        )
        guard pasteboard.changeCount == recoverySnapshot.sourceChangeCount else {
            setCaptureWarning(
                L10n.string("系统剪贴板刚刚发生变化，未覆盖新内容；请重试。")
            )
            return false
        }
        let clearedChangeCount = pasteboard.clearContents()
        guard pasteboard.changeCount == clearedChangeCount else {
            setCaptureWarning(L10n.string("系统剪贴板刚刚发生变化，未覆盖新内容；请重试。"))
            return false
        }
        let didCopy = pasteboard.writeObjects(pasteboardObjects)
        guard didCopy else {
            let pasteboardWasNotReplaced = pasteboard.changeCount == clearedChangeCount
            let didWriteRecovery = pasteboardWasNotReplaced
                && (recoverySnapshot.items.isEmpty
                    || pasteboard.writeObjects(recoverySnapshot.items))
            let didRestorePreviousContent = recoverySnapshot.isComplete
                && didWriteRecovery
            lastChangeCount = pasteboardWasNotReplaced ? pasteboard.changeCount : recoverySnapshot.sourceChangeCount
            setCaptureWarning(
                didRestorePreviousContent
                    ? L10n.string("无法写入系统剪贴板，已恢复之前的内容。")
                    : L10n.string("无法写入系统剪贴板，也无法完整恢复之前的内容。")
            )
            return false
        }

        let completedChangeCount = pasteboard.changeCount
        guard pasteboardContainsRestoreToken(restoreToken),
              pasteboard.changeCount == completedChangeCount else {
            // A different process won the clipboard race. Leave its newer
            // content untouched and keep our previous count so polling sees it.
            lastChangeCount = recoverySnapshot.sourceChangeCount
            setCaptureWarning(
                L10n.string("系统剪贴板刚刚发生变化，未覆盖新内容；请重试。")
            )
            return false
        }

        setCaptureWarning(nil)
        lastChangeCount = completedChangeCount
        resetReadRetryState()
        lastCopiedItemID = item.id

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard self?.lastCopiedItemID == item.id else {
                return
            }
            self?.lastCopiedItemID = nil
        }

        return true
    }

    func index(of item: ClipboardItem) -> Int? {
        items.firstIndex { $0.id == item.id }
    }

    func delete(_ item: ClipboardItem) {
        lastDeletionCanBeUndone = false
        for event in captureEvents.values where event.id == item.id { event.isDeleted = true }
        var updatedItems = items
        updatedItems.removeAll { $0.id == item.id }
        items = updatedItems
    }

    @discardableResult
    func delete(_ item: ClipboardItem, undoManager: UndoManager?) -> Int? {
        guard let index = index(of: item) else {
            return nil
        }

        delete(item)
        if let undoManager {
            registerHistoryUndo(operation: .restore, item: item, undoManager: undoManager)
            lastDeletionCanBeUndone = undoActions.contains {
                $0.item.id == item.id && $0.undoManager === undoManager
            }
        }
        return index
    }

    /// Puts an item back by capture time, so newer items that arrived after it
    /// was deleted stay above it. A newer copy of the same content wins.
    func restore(_ item: ClipboardItem) {
        for event in captureEvents.values where event.id == item.id { event.isDeleted = false }
        var updatedItems = items
        if updatedItems.contains(where: {
            $0.id != item.id && $0.hasSameContent(as: item) && !Self.isOrderedBefore(item, $0)
        }) {
            return
        }
        updatedItems.removeAll { $0.id == item.id || $0.hasSameContent(as: item) }
        let position = updatedItems.firstIndex { Self.isOrderedBefore(item, $0) } ?? updatedItems.endIndex
        updatedItems.insert(item, at: position)
        items = trimmedHistory(from: updatedItems)
    }

    /// Newest first; equal timestamps fall back to a stable identifier order.
    private static func isOrderedBefore(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        lhs.capturedAt == rhs.capturedAt
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.capturedAt > rhs.capturedAt
    }

    private func registerHistoryUndo(
        operation: ClipboardUndoAction.Operation,
        item: ClipboardItem,
        undoManager: UndoManager
    ) {
        // Compatibility rasters are rebuilt on demand, so undo keeps originals only.
        let retainedItem = item.hasRebuildableData ? item.droppingRebuildableData() : item
        guard configuration.maximumUndoItemCount > 0,
              retainedItem.storageByteCount <= configuration.maximumUndoBytes else {
            setCaptureWarning(L10n.string("此条目已删除，因内容过大无法撤销。"))
            return
        }
        let createsGroup = undoManager.groupingLevel == 0
        if createsGroup {
            undoManager.beginUndoGrouping()
        }

        let action = ClipboardUndoAction(
            operation: operation,
            item: retainedItem,
            undoManager: undoManager,
            store: self
        )
        undoActions.append(action)
        undoManager.registerUndo(
            withTarget: action,
            selector: #selector(ClipboardUndoAction.applyHistoryUndo(_:)),
            object: nil
        )
        undoManager.setActionName(L10n.string("删除剪贴板历史"))

        if createsGroup {
            undoManager.endUndoGrouping()
        }
        trimUndoHistory()
    }

    fileprivate func performHistoryUndo(_ action: ClipboardUndoAction) {
        guard undoActions.contains(where: { $0 === action }) else { return }
        undoActions.removeAll { $0 === action }
        guard let undoManager = action.undoManager else {
            return
        }

        switch action.operation {
        case .restore:
            restore(action.item)
            registerHistoryUndo(operation: .delete, item: action.item, undoManager: undoManager)
        case .delete:
            delete(action.item)
            registerHistoryUndo(operation: .restore, item: action.item, undoManager: undoManager)
        }
    }

    private func trimUndoHistory() {
        var retainedBytes = undoActions.reduce(0) { $0 + $1.item.storageByteCount }
        while undoActions.count > configuration.maximumUndoItemCount
            || retainedBytes > configuration.maximumUndoBytes {
            let oldest = undoActions.removeFirst()
            oldest.undoManager?.removeAllActions(withTarget: oldest)
            retainedBytes -= oldest.item.storageByteCount
        }
    }

    private func clearHistoryUndo() {
        for action in undoActions { action.undoManager?.removeAllActions(withTarget: action) }
        undoActions.removeAll()
    }

    func clearHistory() {
        cancelPendingImageCaptures()
        captureEpoch += 1
        captureEvents.removeAll()
        clearHistoryUndo()
        lastDeletionCanBeUndone = false
        latestCaptureSequence += 1
        captureSequenceChangeCount = nil
        lastChangeCount = pasteboard.changeCount
        resetReadRetryState()
        items = []
        lastCopiedItemID = nil
        setCaptureWarning(nil)
        isClearConfirmationPresented = false
    }

    /// Production entry point. AppKit provider reads stay on MainActor; the
    /// image processor receives immutable data and performs heavy work off-main.
    func requestPasteboardCapture() {
        guard isMonitoring, snapshotTask == nil else { return }
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        _ = prepareEvent(changeCount: changeCount)
        let epoch = captureEpoch
        let reader = snapshotReader
        let name = pasteboard.name.rawValue
        let limits = snapshotLimits()
        snapshotTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else {
                self?.snapshotTask = nil
                return
            }
            let outcome = await reader.read(name: name, changeCount: changeCount, limits: limits)
            guard let self else { return }
            self.snapshotTask = nil
            guard !Task.isCancelled, self.isMonitoring, self.captureEpoch == epoch else { return }
            self.consumeSnapshot(outcome, requestedChangeCount: changeCount)
        }
    }

    /// Deterministic synchronous hook for isolated test pasteboards.
    func pollPasteboard() {
        guard isMonitoring else { return }
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        _ = prepareEvent(changeCount: changeCount)
        let result = PasteboardSnapshotReader.readSynchronously(
            pasteboard: pasteboard, changeCount: changeCount, limits: snapshotLimits()
        )
        consumeSnapshot(result, requestedChangeCount: changeCount)
    }

    private func snapshotLimits() -> PasteboardSnapshotReader.Limits {
        var privacy = privacySettings.rules
        if !privacy.ignoredBundleIdentifiers.isEmpty {
            privacy.frontmostBundleIdentifier = frontmostApplicationIdentifier()
        }
        return .init(
            maximumBytes: configuration.maximumImageSnapshotBytes,
            maximumItems: configuration.maximumFileReferenceCount,
            maximumImageCandidates: configuration.maximumSnapshotCandidateCount,
            maximumImageBytes: max(0, min(configuration.maximumImageSnapshotBytes,
                configuration.maximumPendingImageCaptureBytes - pendingImageCaptureBytes)),
            maximumTextBytes: configuration.maximumTextBytes,
            privacy: privacy
        )
    }

    private func consumeSnapshot(_ outcome: PasteboardSnapshotOutcome, requestedChangeCount: Int) {
        guard isMonitoring else { return }
        switch outcome {
        case .changed:
            return
        case .unavailable:
            handlePasteboardMetadataReadFailure(changeCount: requestedChangeCount)
            refreshAccessStatus()
            return
        case .skipped:
            // Intentionally not recorded. Nothing was read, nothing to retry,
            // and no warning: the source asked for discretion.
            captureEvents[requestedChangeCount]?.isDeleted = true
            captureEvents[requestedChangeCount] = nil
            lastChangeCount = max(lastChangeCount, requestedChangeCount)
            resetReadRetryState()
            return
        case .success(let snapshot):
            consume(snapshot)
        }
    }

    private func prepareEvent(changeCount: Int) -> ClipboardCaptureEvent {
        if let event = captureEvents[changeCount] { return event }
        if captureSequenceChangeCount != changeCount {
            latestCaptureSequence += 1
            captureSequenceChangeCount = changeCount
        }
        let event = ClipboardCaptureEvent(
            changeCount: changeCount, epoch: captureEpoch, sequence: latestCaptureSequence
        )
        captureEvents[changeCount] = event
        captureEvents = captureEvents.filter {
            $0.key == changeCount || !$0.value.pendingImageIndexes.isEmpty
        }
        return event
    }

    private func consume(_ snapshot: PasteboardSnapshot) {
        let changeCount = snapshot.changeCount
        if retryChangeCount != changeCount { resetReadRetryState() }
        let event = prepareEvent(changeCount: changeCount)

        if snapshot.tooManyItems {
            lastChangeCount = max(lastChangeCount, changeCount)
            setCaptureWarning(L10n.string(
                "一次复制的项目超过 %lld 个，本次未记录。",
                Int64(configuration.maximumFileReferenceCount)
            ))
            return
        }

        var failures: [ClipboardReadFailureKind] = []
        let fileSources = snapshot.items.filter(\.hasFiles)
        event.isFilesOnly = !fileSources.isEmpty && fileSources.count == snapshot.items.count
        var parsedFiles: [(Int, [URL])] = []
        for source in fileSources {
            if let urls = fileURLs(from: source), !urls.isEmpty {
                parsedFiles.append((source.index, urls))
            } else {
                failures.append(.files)
            }
        }
        if failures.isEmpty {
            let count = parsedFiles.reduce(0) { $0 + $1.1.count }
            if count > configuration.maximumFileReferenceCount {
                event.warnings[.fileCountLimit] = L10n.string(
                    "一次复制的文件超过 %lld 个，本次未记录。",
                    Int64(configuration.maximumFileReferenceCount)
                )
            } else {
                for (index, urls) in parsedFiles {
                    guard let files = ClipboardFileList(urls: urls) else { continue }
                    event.parts[index] = .files(files)
                    // Public file URLs replay native Finder copy semantics. File
                    // contents and auxiliary file thumbnails are never read.
                    event.originals[index] = nil
                    event.warnings[.item(index)] = nil
                }
            }
        } else {
            // A file group is atomic: never silently restore only some files.
            for source in fileSources {
                event.parts[source.index] = nil
                event.originals[source.index] = nil
            }
        }

        for source in snapshot.items where !source.hasFiles {
            let slot = CaptureWarningSlot.item(source.index)
            let imageTypes = source.types.filter(PasteboardSnapshotReader.isImageType)
            let candidates = PasteboardSnapshotReader.imageTypes(
                source.types, maximumCandidates: configuration.maximumSnapshotCandidateCount
            ).compactMap { type -> ImageProcessingCandidate? in
                guard let data = source.representations[type] else { return nil }
                return .init(typeIdentifier: type, data: data)
            }
            let text = validText(source.textRepresentation)
            let oversizedText = source.textRepresentation.map {
                $0.utf8.count > configuration.maximumTextBytes
            } ?? false

            if !imageTypes.isEmpty {
                if !candidates.isEmpty {
                    if event.imageSignatures[source.index] != source.imageSignature {
                        scheduleImage(source, candidates: candidates, text: text, event: event)
                    } else if !event.pendingImageIndexes.contains(source.index),
                              event.parts[source.index] == nil,
                              source.unreadableTypes.contains(where: PasteboardSnapshotReader.isImageType) {
                        failures.append(.image)
                    }
                } else if source.unreadableTypes.contains(where: PasteboardSnapshotReader.isImageType) {
                    failures.append(.image)
                    if let text {
                        resolveText(text, source: source, event: event)
                        event.warnings[slot] = L10n.string("图片暂不可读取，已保留可读取的文字。")
                    }
                } else {
                    event.warnings[slot] = snapshotSizeWarning(snapshot)
                    if let text { resolveText(text, source: source, event: event) }
                }
            } else if let text {
                resolveText(text, source: source, event: event)
                if !source.oversizedTypes.isEmpty || !source.unreadableTypes.isEmpty {
                    event.warnings[slot] = L10n.string("部分格式无法读取或超过限制，已保留可读取的内容。")
                } else {
                    event.warnings[slot] = nil
                }
            } else if oversizedText {
                event.warnings[slot] = textSizeWarning()
            } else if !source.unreadableTypes.isEmpty {
                failures.append(.text)
            } else if !source.oversizedTypes.isEmpty {
                event.warnings[slot] = L10n.string("剪贴板内容超过容量限制，本次未完整记录。")
            } else if !source.types.isEmpty {
                event.warnings[slot] = L10n.string("此类剪贴板内容暂不支持，系统剪贴板中的原内容仍可正常粘贴。")
            }
        }

        if let failure = failures.first {
            if registerReadFailureAndShouldRetry(changeCount: changeCount) {
                event.warnings[.readFailure] = failure.retryMessage
            } else {
                lastChangeCount = max(lastChangeCount, changeCount)
                event.warnings[.readFailure] = failure.finalMessage
            }
            if event.sequence == latestCaptureSequence { setCaptureWarning(event.warnings[.readFailure]) }
        } else {
            lastChangeCount = max(lastChangeCount, changeCount)
            resetReadRetryState()
            event.warnings[.readFailure] = nil
            if event.sequence == latestCaptureSequence {
                setCaptureWarning(event.orderedWarnings.first)
            }
        }
        publish(event)
        refreshAccessStatus()
    }

    private func validText(_ text: String?) -> String? {
        guard let text, text.utf8.count <= configuration.maximumTextBytes else { return nil }
        // Spaces, tabs, newlines, and an explicitly copied empty string are data.
        return text
    }

    /// Keeps the source's text formats in their original order. Plain-text
    /// targets need a text flavor, so one is derived only when the source had
    /// none (for example HTML- or RTF-only content) and the text is not empty.
    private func resolveText(_ text: String, source: PasteboardItemSnapshot, event: ClipboardCaptureEvent) {
        event.parts[source.index] = .text(text)
        var entries = source.types.compactMap { type -> ClipboardRepresentationItem.Entry? in
            guard !PasteboardSnapshotReader.isImageType(type),
                  let data = source.representations[type] else { return nil }
            return .init(type: type, data: data)
        }
        if !entries.contains(where: { $0.type == PasteboardSnapshotReader.plainText }), !text.isEmpty {
            entries.append(.init(type: PasteboardSnapshotReader.plainText, data: Data(text.utf8)))
        }
        event.originals[source.index] = .init(entries: entries)
    }

    /// The decoded image takes the place of the writer's first image type and
    /// is followed by ClipDeck's compatibility rasters; other formats keep their
    /// positions. No plain text is added: an image copied with only HTML or a
    /// URL must keep pasting as an image in apps that prefer text.
    private static func imageOriginal(
        for image: ClipboardImage,
        source: PasteboardItemSnapshot
    ) -> ClipboardRepresentationItem {
        let imageEntries = [ClipboardRepresentationItem.Entry(type: image.pasteboardType.rawValue, data: image.data)]
            + image.derivedRepresentations.map {
                ClipboardRepresentationItem.Entry(type: $0.type.rawValue, data: $0.data, isRebuildable: true)
            }
        var entries: [ClipboardRepresentationItem.Entry] = []
        var insertedImage = false
        for type in source.types {
            if PasteboardSnapshotReader.isImageType(type) {
                if !insertedImage {
                    entries += imageEntries
                    insertedImage = true
                }
            } else if let data = source.representations[type] {
                entries.append(.init(type: type, data: data))
            }
        }
        if !insertedImage { entries.insert(contentsOf: imageEntries, at: 0) }
        return .init(entries: entries)
    }

    private func scheduleImage(
        _ source: PasteboardItemSnapshot,
        candidates: [ImageProcessingCandidate],
        text: String?,
        event: ClipboardCaptureEvent
    ) {
        let slot = CaptureWarningSlot.item(source.index)
        guard !event.pendingImageIndexes.contains(source.index) else { return }
        guard captureTasks.count < configuration.maximumPendingImageCaptures else {
            event.warnings[slot] = L10n.string("图片处理队列已满，本次未记录。")
            return
        }
        let byteCount = source.byteCount
        guard byteCount <= configuration.maximumPendingImageCaptureBytes - pendingImageCaptureBytes else {
            event.warnings[slot] = L10n.string("图片处理队列内存已满，本次未记录。")
            return
        }
        event.imageSignatures[source.index] = source.imageSignature
        event.pendingImageIndexes.insert(source.index)
        pendingImageCaptureBytes += byteCount
        let id = UUID()
        let processor = imageProcessor
        captureTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.captureTasks[id] = nil
                self.pendingImageCaptureBytes = max(0, self.pendingImageCaptureBytes - byteCount)
                event.pendingImageIndexes.remove(source.index)
                if event.pendingImageIndexes.isEmpty,
                   event.changeCount != self.captureSequenceChangeCount {
                    self.captureEvents[event.changeCount] = nil
                }
            }
            var failure: ImageProcessingFailure = .invalidFormat
            for candidate in candidates {
                guard !Task.isCancelled, self.isMonitoring, event.epoch == self.captureEpoch else { return }
                let result = await processor.process(candidate)
                guard !Task.isCancelled, self.isMonitoring, event.epoch == self.captureEpoch else { return }
                switch result {
                case .success(let processed):
                    guard let image = ClipboardImage(processed: processed, textRepresentation: text) else {
                        failure = .thumbnailCreationFailed
                        continue
                    }
                    event.parts[source.index] = .image(image)
                    event.originals[source.index] = Self.imageOriginal(for: image, source: source)
                    event.warnings[slot] = nil
                    event.pendingImageIndexes.remove(source.index)
                    self.publish(event)
                    // A successful sibling must not erase an earlier warning.
                    if event.sequence == self.latestCaptureSequence,
                       let warning = event.orderedWarnings.first {
                        self.setCaptureWarning(warning)
                    }
                    return
                case .failure(.cancelled): return
                case .failure(let value): failure = value
                }
            }
            if let text {
                self.resolveText(text, source: source, event: event)
                event.warnings[slot] = L10n.string("图片无法解析，已保留可读取的文字和文字格式。")
            } else {
                event.warnings[slot] = self.warningMessage(for: failure)
            }
            if source.unreadableTypes.contains(where: PasteboardSnapshotReader.isImageType),
               self.pasteboard.changeCount == event.changeCount {
                // A decodable alternate may become available without a new
                // pasteboard event. Keep bounded retries alive after async failure.
                self.lastChangeCount = event.changeCount - 1
            }
            event.pendingImageIndexes.remove(source.index)
            self.publish(event)
            if event.sequence == self.latestCaptureSequence {
                self.setCaptureWarning(event.warnings[slot])
            }
        }
    }

    private func publish(_ event: ClipboardCaptureEvent) {
        guard event.epoch == captureEpoch, !event.isDeleted else { return }
        enforceEventBudget(event)
        guard event.pendingImageIndexes.isEmpty else { return }
        let ordered = event.parts.sorted { $0.key < $1.key }
        guard !ordered.isEmpty else { return }
        var parts = ordered.map(\.value)
        var originals: [ClipboardRepresentationItem] = []
        for (index, part) in ordered {
            if let original = event.originals[index] {
                originals.append(original)
            } else if case .files(let files) = part {
                originals += files.urls.map { url in
                    .init(entries: [.init(
                        type: NSPasteboard.PasteboardType.fileURL.rawValue,
                        data: Data(url.absoluteString.utf8)
                    )])
                }
            }
        }
        if event.isFilesOnly {
            let urls = parts.flatMap { part -> [URL] in
                if case .files(let files) = part { return files.urls }; return []
            }
            if let files = ClipboardFileList(urls: urls) { parts = [.files(files)] }
        }
        let warning = event.orderedWarnings.joined(separator: "\n")
        let item = ClipboardItem(
            id: event.id, parts: parts, originalItems: originals,
            captureNote: warning.isEmpty ? nil : warning, copiedAt: event.capturedAt
        )
        if let id = insert(item) { event.id = id }
    }

    /// Bounds one clipboard event before it reaches history. Images first try to
    /// fit without their rebuildable compatibility rasters; a part that still
    /// does not fit is left out with a visible note.
    private func enforceEventBudget(_ event: ClipboardCaptureEvent) {
        var retainedBytes = 0
        var rejected = Set<Int>()
        var fileIndexes = Set<Int>()
        for (index, part) in event.parts.sorted(by: { $0.key < $1.key }) {
            let remaining = configuration.maximumImageHistoryBytes - retainedBytes
            let original = event.originals[index]
            var bytes = Self.eventByteCount(part: part, original: original)
            if case .files = part { fileIndexes.insert(index) }
            if bytes > remaining, case .image(let image) = part,
               !image.derivedRepresentations.isEmpty || original?.hasRebuildableData == true {
                let compactImage = image.withoutDerivedRepresentations()
                let compactOriginal = original?.droppingRebuildableData()
                let compactBytes = Self.eventByteCount(part: .image(compactImage), original: compactOriginal)
                if compactBytes <= remaining {
                    event.parts[index] = .image(compactImage)
                    event.originals[index] = compactOriginal
                    bytes = compactBytes
                }
            }
            if bytes > remaining {
                rejected.insert(index)
            } else {
                retainedBytes += bytes
            }
        }
        guard !rejected.isEmpty else { return }
        // File selections stay atomic even when mixed with a large image batch.
        if !rejected.isDisjoint(with: fileIndexes) { rejected.formUnion(fileIndexes) }
        for index in rejected {
            event.parts[index] = nil
            event.originals[index] = nil
        }
        let warning = L10n.string("部分内容超过历史内存上限，已保留可容纳的项目。")
        event.warnings[.memoryBudget] = warning
        if event.sequence == latestCaptureSequence { setCaptureWarning(warning) }
    }

    private static func eventByteCount(
        part: ClipboardItem.Content,
        original: ClipboardRepresentationItem?
    ) -> Int {
        switch part {
        case .text(let text):
            return (original?.byteCount ?? 0) + text.utf8.count
        case .image(let image):
            return original.map { $0.byteCount + image.renderingByteCount } ?? image.storageByteCount
        case .files(let files):
            return files.urls.reduce(0) { $0 + 2 * $1.absoluteString.utf8.count }
        }
    }

    private func fileURLs(from source: PasteboardItemSnapshot) -> [URL]? {
        for type in source.types where type != PasteboardSnapshotReader.legacyFiles
            && PasteboardSnapshotReader.isFileType(type) {
            guard let data = source.representations[type],
                  let value = String(data: data, encoding: .utf8) else { continue }
            if let url = URL(string: value), url.isFileURL { return [url] }
            if value.hasPrefix("/") { return [URL(fileURLWithPath: value)] }
        }
        if let data = source.representations[PasteboardSnapshotReader.legacyFiles],
           let paths = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return nil
    }

    private func snapshotSizeWarning(_ snapshot: PasteboardSnapshot) -> String {
        if snapshot.imageByteLimit < configuration.maximumImageSnapshotBytes {
            return L10n.string("图片处理队列内存已满，本次未记录。")
        }
        return L10n.string("图片剪贴板数据超过 %@，本次未记录。", ByteCountFormatter.string(
            fromByteCount: Int64(configuration.maximumImageSnapshotBytes), countStyle: .file
        ))
    }

    private func textSizeWarning() -> String {
        L10n.string("文字超过 %@，未记录。", ByteCountFormatter.string(
            fromByteCount: Int64(configuration.maximumTextBytes), countStyle: .file
        ))
    }

    /// Waits for both an in-flight provider snapshot and its image jobs.
    func waitForPendingImageCapture() async {
        if let snapshotTask { await snapshotTask.value }
        while !captureTasks.isEmpty {
            let tasks = Array(captureTasks.values)
            for task in tasks { await task.value }
        }
    }

    var isPolling: Bool { pollTimer != nil }

    private func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func cancelPendingImageCaptures() {
        snapshotTask?.cancel()
        for task in captureTasks.values { task.cancel() }
    }

    private func handlePasteboardMetadataReadFailure(changeCount: Int) {
        if registerReadFailureAndShouldRetry(changeCount: changeCount) {
            setCaptureWarning(L10n.string("暂时无法读取剪贴板类型；将自动重试。"))
        } else {
            lastChangeCount = changeCount
            setCaptureWarning(L10n.string("剪贴板连续多次读取失败，本次未记录。"))
        }
    }

    private func registerReadFailureAndShouldRetry(changeCount: Int) -> Bool {
        if retryChangeCount == changeCount { readRetryAttemptCount += 1 }
        else { retryChangeCount = changeCount; readRetryAttemptCount = 1 }
        guard readRetryAttemptCount < configuration.maximumReadRetryAttempts else {
            resetReadRetryState()
            return false
        }
        return true
    }

    private func resetReadRetryState() {
        retryChangeCount = nil
        readRetryAttemptCount = 0
    }

    @discardableResult
    private func insert(_ incoming: ClipboardItem) -> ClipboardItem.ID? {
        var updated = items
        updated.removeAll { $0.id == incoming.id }
        var id = incoming.id
        if let existing = updated.firstIndex(where: { $0.hasSameContent(as: incoming) }) {
            // Slow old image work must not demote a newer copy of the same data.
            guard updated[existing].capturedAt <= incoming.capturedAt else { return nil }
            id = updated.remove(at: existing).id
        }
        updated.append(ClipboardItem(
            id: id, parts: incoming.parts, originalItems: incoming.originalItems,
            captureNote: incoming.captureNote, copiedAt: incoming.capturedAt
        ))
        updated.sort(by: Self.isOrderedBefore)
        items = trimmedHistory(from: updated)
        if !items.contains(where: { $0.id == id }) {
            setCaptureWarning(L10n.string("此条目超过历史内存上限，未记录。"))
            return nil
        }
        return id
    }

    /// Keeps the newest items within the count and byte budgets. Before an
    /// older image is evicted, its rebuildable compatibility rasters are
    /// released instead, so far more images stay in history.
    private func trimmedHistory(from sourceItems: [ClipboardItem]) -> [ClipboardItem] {
        var retained: [ClipboardItem] = []
        var bytes = 0
        for item in sourceItems {
            guard retained.count < configuration.maximumItemCount else { break }
            let remaining = configuration.maximumImageHistoryBytes - bytes
            var candidate = item
            if candidate.storageByteCount > remaining, candidate.hasRebuildableData {
                candidate = candidate.droppingRebuildableData()
            }
            guard candidate.storageByteCount <= remaining else { continue }
            bytes += candidate.storageByteCount
            retained.append(candidate)
        }
        return retained
    }

    /// Checks referenced files without letting an unresponsive volume freeze the UI.
    private func unavailableFilesWarning(for item: ClipboardItem) -> String? {
        let files = item.parts.flatMap { part -> [ClipboardFileReference] in
            if case .files(let list) = part { return list.references }
            return []
        }
        let result = FileAvailability.check(files.map(\.url))
        guard !result.unavailableIndexes.isEmpty else { return nil }
        if result.timedOut {
            return L10n.string("文件所在位置暂时没有响应，未更改系统剪贴板。")
        }
        if result.unavailableIndexes.count == 1, let index = result.unavailableIndexes.first {
            return L10n.string("“%@”不存在或暂不可用，未更改系统剪贴板。", files[index].displayName)
        }
        return L10n.string(
            "%lld 个文件不存在或暂不可用，未更改系统剪贴板。",
            Int64(result.unavailableIndexes.count)
        )
    }

    private func pasteboardContainsRestoreToken(_ restoreToken: String) -> Bool {
        pasteboard.pasteboardItems?.contains { item in
            item.string(forType: restoreTokenPasteboardType) == restoreToken
        } == true
    }

    private func setPreparationWarning(for item: ClipboardItem) {
        switch item.content {
        case .text:
            setCaptureWarning(L10n.string("无法准备这段文字，请稍后再试。"))
        case .image:
            setCaptureWarning(
                L10n.string("这张图片暂时无法复制，请重新截取或复制原图。")
            )
        case .files:
            setCaptureWarning(
                L10n.string("无法准备剪贴板内容，当前系统剪贴板未更改。")
            )
        }
    }

    private func warningMessage(for failure: ImageProcessingFailure) -> String {
        switch failure {
        case .cancelled:
            return L10n.string("图片处理已取消。")
        case .rawDataTooLarge:
            return L10n.string("图片原始数据过大，未记录。")
        case .finalDataTooLarge:
            return L10n.string("图片超过 32 MB，未记录。")
        case .dimensionsTooLarge:
            return L10n.string("图片尺寸超过 1600 万像素，未记录。")
        case .invalidFormat, .thumbnailCreationFailed:
            return L10n.string("检测到图片，但格式无法解析。")
        case .compatibilityEncodingFailed:
            return L10n.string("图片无法生成通用剪贴板格式，未记录。")
        }
    }

    private func setCaptureWarning(_ warning: String?) {
        guard captureWarning != warning else {
            return
        }
        captureWarning = warning
    }

    deinit {
        pollTimer?.invalidate()
        snapshotTask?.cancel()
        for task in captureTasks.values {
            task.cancel()
        }
    }

    private static func removeLegacyStoredHistory() -> Bool {
        let fileManager = FileManager.default
        guard let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return false
        }

        let legacyHistoryURL = supportDirectory
            .appendingPathComponent("ClipDeck", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)

        guard fileManager.fileExists(atPath: legacyHistoryURL.path) else {
            return true
        }

        do {
            try fileManager.removeItem(at: legacyHistoryURL)
            return true
        } catch {
            return false
        }
    }

    private func refreshAccessStatus() {
        let updatedStatus: String?
        if #available(macOS 15.4, *) {
            switch pasteboard.accessBehavior {
            case .alwaysDeny:
                updatedStatus = L10n.string(
                    "系统已禁止 ClipDeck 读取剪贴板。请在“系统设置 > 隐私与安全性 > 剪贴板”中允许它。"
                )
            case .default, .ask, .alwaysAllow:
                updatedStatus = nil
            @unknown default:
                updatedStatus = nil
            }
        } else {
            updatedStatus = nil
        }

        guard accessStatus != updatedStatus else {
            return
        }
        accessStatus = updatedStatus
    }
}
