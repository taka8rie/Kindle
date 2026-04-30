import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class KindleViewModel: ObservableObject {
    @Published var dependencyReady = false
    @Published var selectedBooks: [BookCandidate] = []
    @Published var kindleItems: [KindleItem] = []
    @Published var currentKindlePath = "/documents"
    @Published var deviceInfo = KindleDeviceInfo()
    @Published var detectedDeviceName = "尚未检测设备"
    @Published var isBusy = false
    @Published var statusMessage = "连接 Kindle 后可以先做 USB 检测，再选择书籍导入。"
    @Published var logLines: [String] = []

    private let service = MTPService()

    var visibleKindleItems: [KindleItem] {
        let currentPath = KindleItem.normalizedPath(currentKindlePath)
        return kindleItems
            .filter { $0.parentPath.localizedCaseInsensitiveCompare(currentPath) == .orderedSame }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .folder
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var canGoUpInKindle: Bool {
        KindleItem.normalizedPath(currentKindlePath) != "/"
    }

    init() {
        refreshDependencyStatus()
    }

    func refreshDependencyStatus() {
        dependencyReady = service.checkDependency()
        if dependencyReady {
            appendLog("已找到 libmtp 命令行工具。")
        } else {
            appendLog("未找到完整的 libmtp 命令行工具，请先运行：brew install libmtp")
        }
    }

    func chooseBooks() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = supportedBookTypes()

        if panel.runModal() == .OK {
            let incoming = panel.urls.map(BookCandidate.init(url:))
            selectedBooks = Array(Set(selectedBooks).union(incoming)).sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
            statusMessage = "已选择 \(selectedBooks.count) 本书。"
            appendLog("已选择 \(incoming.count) 个文件。")
        }
    }

    func removeBooks(at offsets: IndexSet) {
        selectedBooks.remove(atOffsets: offsets)
    }

    func detectKindle() {
        guard !isBusy else { return }

        let service = self.service
        runTask(label: "检测 Kindle", operation: {
            try service.detectDevice()
        }, onSuccess: { snapshot in
            self.detectedDeviceName = snapshot.title
            self.deviceInfo.deviceName = snapshot.title
            self.deviceInfo.model = snapshot.title
            self.statusMessage = "USB 已看到 Kindle，可以直接复制到 /documents。"
            self.appendLog(snapshot.rawOutput)
        })
    }

    func connectKindleDevice() {
        guard !isBusy else { return }

        let service = self.service
        runTask(label: "连接装置", operation: {
            try service.loadLibrarySnapshot()
        }, onSuccess: { snapshot in
            self.deviceInfo = snapshot.deviceInfo
            self.kindleItems = snapshot.items
            self.keepCurrentFolderVisible()
            self.detectedDeviceName = snapshot.deviceInfo.summaryTitle
            self.statusMessage = "已连接装置并读取缓存。"
            self.appendLog("已连接装置并读取缓存。")
        })
    }

    func openKindleItem(_ item: KindleItem) {
        guard item.canOpen, let path = item.normalizedPath else {
            if item.isKindleSidecarFolder {
                statusMessage = "\(item.name) 是 Kindle 资料夹，不作为普通文件夹打开。"
            }
            return
        }
        currentKindlePath = path
        statusMessage = "已打开 \(path)。"
    }

    func goUpInKindle() {
        currentKindlePath = parentPath(of: currentKindlePath)
        statusMessage = "已打开 \(currentKindlePath)。"
    }

    func importDroppedBooks(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let urlBuffer = URLBuffer()

        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }

                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }

                guard let url else { return }
                urlBuffer.append(url)
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.importBookURLs(urlBuffer.value())
        }

        return true
    }

    func importBooks() {
        guard !isBusy else { return }
        guard !selectedBooks.isEmpty else {
            statusMessage = "请先选择要导入的书籍。"
            appendLog("导入已取消：还没有选择文件。")
            return
        }

        let urls = selectedBooks.map(\.url)
        importBookURLs(urls)
    }

    private func importBookURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !isBusy else { return }

        let service = self.service
        let targetFolder = KindleItem.normalizedPath(currentKindlePath)
        appendLog("准备复制 \(urls.count) 个文件到 Kindle：\(targetFolder)。")
        runTask(label: "导入书籍", operation: {
            try service.transfer(urls, to: targetFolder)
        }, onSuccess: { result in
            let failureCount = result.failures.count

            if failureCount == 0 {
                self.statusMessage = "已复制到 \(targetFolder)，共 \(result.successes.count) 个文件。"
                self.addCopiedFilesToVisibleList(result.successes, targetFolder: targetFolder)
            } else {
                self.statusMessage = "复制完成，成功 \(result.successes.count) 个，失败 \(failureCount) 个。"
                self.addCopiedFilesToVisibleList(result.successes, targetFolder: targetFolder)
            }

            result.successes.forEach { self.appendLog("导入成功：\($0.lastPathComponent)") }
            result.failures.forEach { self.appendLog("导入失败：\($0.url.lastPathComponent)\n\($0.reason)") }
        })
    }

    private func runTask<T: Sendable>(
        label: String,
        operation: @escaping @Sendable () throws -> T,
        onSuccess: @escaping @MainActor (T) -> Void
    ) {
        isBusy = true
        statusMessage = "\(label)中..."

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                TaskOutcome(catching: operation)
            }.value

            switch outcome {
            case .success(let value):
                isBusy = false
                onSuccess(value)
            case .failure(let message):
                statusMessage = message
                appendLog("\(label)失败：\(message)")
                isBusy = false
            }
        }
    }

    private func appendLog(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append("[\(Self.timestampFormatter.string(from: Date()))] \(trimmed)")
    }

    private func keepCurrentFolderVisible() {
        let normalizedCurrentPath = KindleItem.normalizedPath(currentKindlePath)
        let folderPaths = Set(kindleItems.compactMap { item in
            item.kind == .folder ? item.normalizedPath?.lowercased() : nil
        })

        if normalizedCurrentPath == "/" || folderPaths.contains(normalizedCurrentPath.lowercased()) {
            currentKindlePath = normalizedCurrentPath
        } else if folderPaths.contains("/documents") {
            currentKindlePath = "/documents"
        } else {
            currentKindlePath = "/"
        }
    }

    private func addCopiedFilesToVisibleList(_ urls: [URL], targetFolder: String) {
        let normalizedTarget = KindleItem.normalizedPath(targetFolder)
        let existingPaths = Set(kindleItems.compactMap { $0.normalizedPath?.lowercased() })
        let additions = urls.compactMap { url -> KindleItem? in
            guard url.isFileURL else { return nil }

            let name = url.lastPathComponent
            let path = KindleItem.normalizedPath("\(normalizedTarget)/\(name)")
            guard !existingPaths.contains(path.lowercased()) else { return nil }

            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init)

            return KindleItem(
                id: "local-\(path)",
                name: name,
                kind: .file,
                sizeBytes: size,
                parentID: nil,
                path: path,
                fileType: nil
            )
        }

        guard !additions.isEmpty else { return }
        kindleItems.append(contentsOf: additions)
    }

    private func parentPath(of path: String) -> String {
        let normalized = KindleItem.normalizedPath(path)
        guard normalized != "/" else { return "/" }
        let components = normalized.split(separator: "/").map(String.init)
        guard components.count > 1 else { return "/" }
        return "/" + components.dropLast().joined(separator: "/")
    }

    private func supportedBookTypes() -> [UTType] {
        let extensions = ["epub", "pdf", "mobi", "azw", "azw3", "kfx", "txt", "cbz"]
        return extensions.compactMap { UTType(filenameExtension: $0) }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private final class URLBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func value() -> [URL] {
        lock.lock()
        let current = urls
        lock.unlock()
        return current
    }
}

private enum TaskOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(String)

    init(catching operation: () throws -> Value) {
        do {
            self = .success(try operation())
        } catch {
            self = .failure(error.localizedDescription)
        }
    }
}
