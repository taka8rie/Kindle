import Foundation

struct BookCandidate: Identifiable, Hashable, Sendable {
    let url: URL

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }
}

struct DeviceSnapshot: Sendable {
    let title: String
    let rawOutput: String
}

enum KindleItemKind: String, Sendable {
    case folder = "文件夹"
    case file = "文件"
}

struct KindleItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: KindleItemKind
    let sizeBytes: Int64?
    let parentID: UInt64?
    let path: String?
    let fileType: String?

    var displayPath: String {
        path ?? (parentID.map { "Parent ID: \($0)" } ?? "Kindle")
    }

    var formattedSize: String {
        guard let sizeBytes else { return "未知大小" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var normalizedPath: String? {
        path.map(Self.normalizedPath)
    }

    var isKindleSidecarFolder: Bool {
        kind == .folder && name.lowercased().hasSuffix(".sdr")
    }

    var canOpen: Bool {
        kind == .folder && !isKindleSidecarFolder
    }

    var displayKind: String {
        if isKindleSidecarFolder {
            return "资料夹"
        }
        return kind.rawValue
    }

    var parentPath: String {
        guard let path = normalizedPath, path != "/" else {
            return "/"
        }

        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else {
            return "/"
        }

        return "/" + components.dropLast().joined(separator: "/")
    }

    static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized.isEmpty ? "/" : normalized
    }
}

struct KindleDeviceInfo: Sendable {
    var deviceName: String?
    var model: String?
    var storageDescription: String?
    var freeSpaceDescription: String?

    var summaryTitle: String {
        deviceName ?? model ?? "Kindle"
    }
}

struct KindleLibrarySnapshot: Sendable {
    let deviceInfo: KindleDeviceInfo
    let items: [KindleItem]
    let rawDeviceOutput: String
    let rawFilesOutput: String
}

struct TransferFailure: Sendable {
    let url: URL
    let reason: String
}

struct TransferBatchResult: Sendable {
    let successes: [URL]
    let failures: [TransferFailure]
}
