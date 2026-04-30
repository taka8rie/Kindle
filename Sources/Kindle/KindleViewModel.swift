import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class KindleViewModel: ObservableObject {
    @Published var dependencyReady = false
    @Published var selectedBooks: [BookCandidate] = []
    @Published var detectedDeviceName = "尚未检测设备"
    @Published var isBusy = false
    @Published var statusMessage = "先安装 libmtp，然后连接 Kindle 并点击“检测 Kindle”。"
    @Published var logLines: [String] = []

    private let service = MTPService()

    init() {
        refreshDependencyStatus()
    }

    func refreshDependencyStatus() {
        dependencyReady = service.checkDependency()
        if dependencyReady {
            appendLog("已找到 libmtp 命令行工具。")
        } else {
            appendLog("未找到 libmtp，请先运行：brew install libmtp")
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

        runTask(label: "检测 Kindle") {
            let snapshot = try self.service.detectDevice()
            self.detectedDeviceName = snapshot.title
            self.statusMessage = "已检测到设备，可以开始导书。"
            self.appendLog(snapshot.rawOutput)
        }
    }

    func importBooks() {
        guard !isBusy else { return }
        guard !selectedBooks.isEmpty else {
            statusMessage = "请先选择要导入的书籍。"
            appendLog("导入已取消：还没有选择文件。")
            return
        }

        let urls = selectedBooks.map(\.url)
        runTask(label: "导入书籍") {
            self.appendLog("准备导入 \(urls.count) 个文件到 Kindle 的 documents 目录。")
            let result = try self.service.transfer(urls)
            let failureCount = result.failures.count

            if failureCount == 0 {
                self.statusMessage = "导入完成，共 \(result.successes.count) 本。"
            } else {
                self.statusMessage = "导入完成，成功 \(result.successes.count) 本，失败 \(failureCount) 本。"
            }

            result.successes.forEach { self.appendLog("导入成功：\($0.lastPathComponent)") }
            result.failures.forEach { self.appendLog("导入失败：\($0.url.lastPathComponent)\n\($0.reason)") }
        }
    }

    private func runTask(label: String, operation: @escaping @Sendable @MainActor () throws -> Void) {
        isBusy = true
        statusMessage = "\(label)中..."

        Task {
            defer { isBusy = false }

            do {
                try operation()
            } catch {
                statusMessage = error.localizedDescription
                appendLog("\(label)失败：\(error.localizedDescription)")
            }
        }
    }

    private func appendLog(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append("[\(Self.timestampFormatter.string(from: Date()))] \(trimmed)")
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
