import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

private final class ClipboardUndoAction: NSObject {
    enum Operation {
        case restore
        case delete
    }

    let operation: Operation
    let item: ClipboardItem
    let index: Int
    weak var undoManager: UndoManager?

    init(
        operation: Operation,
        item: ClipboardItem,
        index: Int,
        undoManager: UndoManager
    ) {
        self.operation = operation
        self.item = item
        self.index = index
        self.undoManager = undoManager
    }
}

/// In-memory clipboard history for the current app session only.
@MainActor
final class ClipboardStore: NSObject, ObservableObject {
    struct Configuration: Sendable {
        var maximumItemCount: Int
        var maximumTextBytes: Int
        var maximumImageHistoryBytes: Int
        var pollingInterval: TimeInterval
        var pollingTolerance: TimeInterval
        var maximumReadRetryAttempts: Int
        var maximumPendingImageCaptures: Int
        var maximumSnapshotCandidateCount: Int

        init(
            maximumItemCount: Int = 40,
            maximumTextBytes: Int = 50_000,
            maximumImageHistoryBytes: Int = 128 * 1024 * 1024,
            pollingInterval: TimeInterval = 0.5,
            pollingTolerance: TimeInterval = 0.1,
            maximumReadRetryAttempts: Int = 3,
            maximumPendingImageCaptures: Int = 4,
            maximumSnapshotCandidateCount: Int = 3
        ) {
            self.maximumItemCount = max(1, maximumItemCount)
            self.maximumTextBytes = max(1, maximumTextBytes)
            self.maximumImageHistoryBytes = max(0, maximumImageHistoryBytes)
            self.pollingInterval = max(0.1, pollingInterval)
            self.pollingTolerance = max(0, pollingTolerance)
            self.maximumReadRetryAttempts = max(1, maximumReadRetryAttempts)
            self.maximumPendingImageCaptures = max(1, maximumPendingImageCaptures)
            self.maximumSnapshotCandidateCount = max(1, maximumSnapshotCandidateCount)
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
            resetReadRetryState()
            latestCaptureSequence += 1

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

    private static let defaultMonitoringKey = "com.qiaoni.ClipDeck.isMonitoring"

    private let pasteboard: NSPasteboard
    private let userDefaults: UserDefaults
    private let monitoringDefaultsKey: String
    private let imageProcessor: any ImageProcessing
    private let configuration: Configuration

    private var lastChangeCount: Int
    // The timer is created and mutated on MainActor; unsafe isolation only lets
    // nonisolated deinit invalidate the RunLoop-owned reference.
    nonisolated(unsafe) private var pollTimer: Timer?
    private var captureTasks: [UUID: Task<Void, Never>] = [:]
    private var retryChangeCount: Int?
    private var readRetryAttemptCount = 0
    private var latestCaptureSequence = 0

    init(
        pasteboard: NSPasteboard = .general,
        startsMonitoring: Bool = true,
        performsLegacyCleanup: Bool = true,
        userDefaults: UserDefaults = .standard,
        monitoringDefaultsKey: String = ClipboardStore.defaultMonitoringKey,
        imageProcessor: any ImageProcessing = ImageProcessor(),
        configuration: Configuration = .default
    ) {
        self.pasteboard = pasteboard
        self.userDefaults = userDefaults
        self.monitoringDefaultsKey = monitoringDefaultsKey
        self.imageProcessor = imageProcessor
        self.configuration = configuration
        self.lastChangeCount = pasteboard.changeCount
        self.isMonitoring = userDefaults.object(forKey: monitoringDefaultsKey) as? Bool ?? true
        self.accessStatus = nil
        self.storageWarning = nil
        self.captureWarning = nil
        self.lastCopiedItemID = nil
        super.init()

        if performsLegacyCleanup, !Self.removeLegacyStoredHistory() {
            storageWarning = "无法删除旧版本地历史；请退出应用后检查 Application Support/ClipDeck。"
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
                self?.pollPasteboard()
            }
        }
        timer.tolerance = min(configuration.pollingTolerance, configuration.pollingInterval)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func filteredItems(matching query: String) -> [ClipboardItem] {
        let normalizedQuery = ClipboardItem.normalizedSearchText(
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !normalizedQuery.isEmpty else {
            return items
        }

        return items.filter {
            $0.searchableText.contains(normalizedQuery)
        }
    }

    @discardableResult
    func copy(_ item: ClipboardItem) -> Bool {
        latestCaptureSequence += 1

        let didCopy: Bool
        switch item.content {
        case .text(let text):
            let pasteboardItem = NSPasteboardItem()
            guard pasteboardItem.setString(text, forType: .string) else {
                setCaptureWarning("无法准备这段文字，请稍后再试。")
                return false
            }
            pasteboard.clearContents()
            didCopy = pasteboard.writeObjects([pasteboardItem])
        case .image(let image):
            guard let pasteboardItem = makePasteboardItem(for: image) else {
                setCaptureWarning("这张图片暂时无法复制，请重新截取或复制原图。")
                return false
            }
            pasteboard.clearContents()
            didCopy = pasteboard.writeObjects([pasteboardItem])
        }

        guard didCopy else {
            setCaptureWarning("无法写入系统剪切板，请稍后再试。")
            return false
        }

        setCaptureWarning(nil)
        lastChangeCount = pasteboard.changeCount
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
            registerRestoreUndo(
                for: item,
                at: index,
                undoManager: undoManager
            )
        }
        return index
    }

    func restore(_ item: ClipboardItem, at index: Int) {
        var updatedItems = items
        updatedItems.removeAll { $0.id == item.id }
        let safeIndex = min(max(0, index), updatedItems.count)
        updatedItems.insert(item, at: safeIndex)
        items = trimmedHistory(from: updatedItems)
    }

    private func registerRestoreUndo(
        for item: ClipboardItem,
        at index: Int,
        undoManager: UndoManager
    ) {
        registerHistoryUndo(
            operation: .restore,
            item: item,
            at: index,
            undoManager: undoManager
        )
    }

    private func registerDeleteRedo(
        for item: ClipboardItem,
        at index: Int,
        undoManager: UndoManager
    ) {
        registerHistoryUndo(
            operation: .delete,
            item: item,
            at: index,
            undoManager: undoManager
        )
    }

    private func registerHistoryUndo(
        operation: ClipboardUndoAction.Operation,
        item: ClipboardItem,
        at index: Int,
        undoManager: UndoManager
    ) {
        let createsGroup = undoManager.groupingLevel == 0
        if createsGroup {
            undoManager.beginUndoGrouping()
        }

        let action = ClipboardUndoAction(
            operation: operation,
            item: item,
            index: index,
            undoManager: undoManager
        )
        undoManager.registerUndo(
            withTarget: self,
            selector: #selector(performHistoryUndo(_:)),
            object: action
        )
        undoManager.setActionName("删除剪贴板历史")

        if createsGroup {
            undoManager.endUndoGrouping()
        }
    }

    @objc private func performHistoryUndo(_ action: ClipboardUndoAction) {
        guard let undoManager = action.undoManager else {
            return
        }

        switch action.operation {
        case .restore:
            restore(action.item, at: action.index)
            registerDeleteRedo(
                for: action.item,
                at: action.index,
                undoManager: undoManager
            )
        case .delete:
            delete(action.item)
            registerRestoreUndo(
                for: action.item,
                at: action.index,
                undoManager: undoManager
            )
        }
    }

    func clearHistory() {
        cancelPendingImageCaptures()
        latestCaptureSequence += 1
        lastChangeCount = pasteboard.changeCount
        resetReadRetryState()
        items = []
        lastCopiedItemID = nil
        setCaptureWarning(nil)
        isClearConfirmationPresented = false
    }

    func pollPasteboard() {
        guard isMonitoring else {
            return
        }

        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else {
            return
        }

        if retryChangeCount != currentChangeCount {
            resetReadRetryState()
        }

        latestCaptureSequence += 1
        let captureSequence = latestCaptureSequence
        guard let pasteboardTypes = pasteboard.types else {
            handlePasteboardMetadataReadFailure(changeCount: currentChangeCount)
            refreshAccessStatus()
            return
        }

        let imageTypes = preferredImageTypes(from: pasteboardTypes)
        if !imageTypes.isEmpty {
            snapshotAndBeginImageCapture(
                types: imageTypes,
                changeCount: currentChangeCount,
                capturedAt: .now,
                captureSequence: captureSequence
            )
            refreshAccessStatus()
            return
        }

        captureTextOrUnsupportedContent(
            advertisedTypes: pasteboardTypes,
            changeCount: currentChangeCount,
            capturedAt: .now
        )
        refreshAccessStatus()
    }

    /// A deterministic test/automation hook for the currently pending image capture.
    func waitForPendingImageCapture() async {
        let tasks = Array(captureTasks.values)
        for task in tasks {
            await task.value
        }
    }

    var isPolling: Bool {
        pollTimer != nil
    }

    private func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func snapshotAndBeginImageCapture(
        types: [NSPasteboard.PasteboardType],
        changeCount: Int,
        capturedAt: Date,
        captureSequence: Int
    ) {
        guard captureTasks.count < configuration.maximumPendingImageCaptures else {
            lastChangeCount = changeCount
            resetReadRetryState()
            setCaptureWarning("图片处理队列已满，本次未记录。")
            return
        }

        var candidates: [ImageProcessingCandidate] = []
        candidates.reserveCapacity(configuration.maximumSnapshotCandidateCount)
        var encounteredReadFailure = false

        for pasteboardType in types {
            if pasteboardType == .tiff, !candidates.isEmpty {
                continue
            }
            guard pasteboard.changeCount == changeCount else {
                break
            }
            guard let imageData = pasteboard.data(forType: pasteboardType) else {
                encounteredReadFailure = true
                continue
            }

            candidates.append(
                ImageProcessingCandidate(
                    typeIdentifier: pasteboardType.rawValue,
                    data: imageData
                )
            )
            if candidates.count >= configuration.maximumSnapshotCandidateCount {
                break
            }
        }

        guard !candidates.isEmpty else {
            if encounteredReadFailure {
                if registerReadFailureAndShouldRetry(changeCount: changeCount) {
                    setCaptureWarning("检测到图片，但暂时无法读取；将自动重试。")
                } else {
                    lastChangeCount = changeCount
                    setCaptureWarning("图片连续多次读取失败，本次未记录。")
                }
            }
            return
        }

        // The immutable Data snapshots allow later clipboard changes to be
        // captured immediately while ImageProcessor serializes heavy decoding.
        lastChangeCount = changeCount
        resetReadRetryState()
        setCaptureWarning(nil)
        beginImageCapture(
            candidates: candidates,
            capturedAt: capturedAt,
            captureSequence: captureSequence
        )
    }

    private func beginImageCapture(
        candidates: [ImageProcessingCandidate],
        capturedAt: Date,
        captureSequence: Int
    ) {
        let captureID = UUID()
        let imageProcessor = imageProcessor
        captureTasks[captureID] = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.captureTasks.removeValue(forKey: captureID)
            }

            var lastFailure: ImageProcessingFailure?

            for candidate in candidates {
                guard !Task.isCancelled, self.isMonitoring else {
                    return
                }

                let outcome = await imageProcessor.process(candidate)

                guard !Task.isCancelled, self.isMonitoring else {
                    return
                }

                switch outcome {
                case .success(let processedImage):
                    guard let image = ClipboardImage(processed: processedImage) else {
                        lastFailure = .thumbnailCreationFailed
                        continue
                    }
                    self.insert(.image(image), capturedAt: capturedAt)
                    if captureSequence == self.latestCaptureSequence {
                        self.setCaptureWarning(nil)
                    }
                    self.refreshAccessStatus()
                    return
                case .failure(.cancelled):
                    return
                case .failure(let failure):
                    lastFailure = failure
                }
            }

            if captureSequence == self.latestCaptureSequence {
                self.setCaptureWarning(
                    self.warningMessage(for: lastFailure ?? .invalidFormat)
                )
            }
            self.refreshAccessStatus()
        }
    }

    private func cancelPendingImageCaptures() {
        let tasks = Array(captureTasks.values)
        captureTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private func handlePasteboardMetadataReadFailure(changeCount: Int) {
        if registerReadFailureAndShouldRetry(changeCount: changeCount) {
            setCaptureWarning("暂时无法读取剪贴板类型；将自动重试。")
        } else {
            lastChangeCount = changeCount
            setCaptureWarning("剪贴板连续多次读取失败，本次未记录。")
        }
    }

    private func registerReadFailureAndShouldRetry(changeCount: Int) -> Bool {
        if retryChangeCount == changeCount {
            readRetryAttemptCount += 1
        } else {
            retryChangeCount = changeCount
            readRetryAttemptCount = 1
        }

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

    private func captureTextOrUnsupportedContent(
        advertisedTypes: [NSPasteboard.PasteboardType],
        changeCount: Int,
        capturedAt: Date
    ) {
        guard let text = pasteboard.string(forType: .string) else {
            if advertisedTypes.contains(.string) {
                if registerReadFailureAndShouldRetry(changeCount: changeCount) {
                    setCaptureWarning("检测到文字，但暂时无法读取；将自动重试。")
                } else {
                    lastChangeCount = changeCount
                    setCaptureWarning("文字连续多次读取失败，本次未记录。")
                }
                return
            }

            lastChangeCount = changeCount
            resetReadRetryState()
            setCaptureWarning(nil)
            return
        }

        lastChangeCount = changeCount
        resetReadRetryState()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setCaptureWarning(nil)
            return
        }

        guard text.utf8.count <= configuration.maximumTextBytes else {
            let maximumSize = ByteCountFormatter.string(
                fromByteCount: Int64(configuration.maximumTextBytes),
                countStyle: .file
            )
            setCaptureWarning("文字超过 \(maximumSize)，未记录。")
            return
        }

        insert(.text(text), capturedAt: capturedAt)
        setCaptureWarning(nil)
    }

    private func preferredImageTypes(
        from pasteboardTypes: [NSPasteboard.PasteboardType]
    ) -> [NSPasteboard.PasteboardType] {
        pasteboardTypes.enumerated()
            .filter { _, pasteboardType in
                guard let contentType = UTType(pasteboardType.rawValue) else {
                    return false
                }

                return contentType.conforms(to: .image)
            }
            .sorted { left, right in
                let leftPriority = imageTypePriority(left.element)
                let rightPriority = imageTypePriority(right.element)
                if leftPriority != rightPriority {
                    return leftPriority < rightPriority
                }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    private func imageTypePriority(_ type: NSPasteboard.PasteboardType) -> Int {
        if type == .png {
            return 1
        }
        if type == .tiff {
            return 2
        }
        return 0
    }

    private func insert(_ content: ClipboardItem.Content, capturedAt: Date) {
        let incomingItem = ClipboardItem(content: content, copiedAt: capturedAt)
        var updatedItems = items
        let existingID: ClipboardItem.ID?
        if let existingIndex = updatedItems.firstIndex(where: {
            $0.hasSameContent(as: incomingItem)
        }) {
            existingID = updatedItems.remove(at: existingIndex).id
        } else {
            existingID = nil
        }

        updatedItems.append(
            ClipboardItem(
                id: existingID ?? incomingItem.id,
                content: content,
                copiedAt: capturedAt
            )
        )
        updatedItems.sort {
            if $0.capturedAt != $1.capturedAt {
                return $0.capturedAt > $1.capturedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        items = trimmedHistory(from: updatedItems)
    }

    private func trimmedHistory(from sourceItems: [ClipboardItem]) -> [ClipboardItem] {
        var retainedItems: [ClipboardItem] = []
        retainedItems.reserveCapacity(min(sourceItems.count, configuration.maximumItemCount))
        var retainedImageBytes = 0

        for item in sourceItems {
            guard retainedItems.count < configuration.maximumItemCount else {
                break
            }

            if let image = item.image {
                guard retainedImageBytes <= configuration.maximumImageHistoryBytes,
                      image.data.count
                        <= configuration.maximumImageHistoryBytes - retainedImageBytes else {
                    continue
                }
                retainedImageBytes += image.data.count
            }

            retainedItems.append(item)
        }

        return retainedItems
    }

    private func makePasteboardItem(for image: ClipboardImage) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        guard item.setData(image.data, forType: image.pasteboardType) else {
            return nil
        }

        return item
    }

    private func warningMessage(for failure: ImageProcessingFailure) -> String {
        switch failure {
        case .cancelled:
            return "图片处理已取消。"
        case .rawDataTooLarge:
            return "图片原始数据过大，未记录。"
        case .finalDataTooLarge:
            return "图片超过 32 MB，未记录。"
        case .dimensionsTooLarge:
            return "图片尺寸超过 2000 万像素，未记录。"
        case .invalidFormat, .thumbnailCreationFailed:
            return "检测到图片，但格式无法解析。"
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
                updatedStatus = "系统已禁止 ClipDeck 读取剪贴板。请在“系统设置 > 隐私与安全性 > 剪贴板”中允许它。"
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
