import Foundation

enum MTPServiceError: Error, LocalizedError, Sendable {
    case libMTPMissing
    case commandMissing(String)
    case noDeviceDetected(String)
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .libMTPMissing:
            return "未检测到 libmtp。请先执行 `brew install libmtp`。"
        case .commandMissing(let command):
            return "缺少 libmtp 命令：\(command)。请重新执行 `brew install libmtp`。"
        case .noDeviceDetected(let output):
            return output.isEmpty ? "没有检测到已连接的 Kindle。" : output
        case .transferFailed(let message):
            return message
        }
    }
}

struct MTPService: Sendable {
    private let runner = ShellCommandRunner()
    private let agent = MTPAgent()
    private let candidateFolders = ["/documents", "/Documents"]

    func checkDependency() -> Bool {
        helperExecutablePath() != nil || runner.commandExists("mtp-sendfile")
    }

    func detectDevice() throws -> DeviceSnapshot {
        guard checkDependency() else {
            throw MTPServiceError.libMTPMissing
        }

        let result = try runner.run(executable: "ioreg", arguments: ["-p", "IOUSB", "-l", "-a", "-w", "0"], timeout: 8)

        guard let deviceName = findKindleName(in: result.standardOutput) else {
            throw MTPServiceError.noDeviceDetected("没有在 USB 设备列表里看到 Kindle。请确认 Kindle 仍停留在“已连接计算机”界面，并且 USB 线支持数据传输。")
        }

        return DeviceSnapshot(title: deviceName, rawOutput: "USB 检测到：\(deviceName)")
    }

    func loadLibrarySnapshot() throws -> KindleLibrarySnapshot {
        let usbSnapshot = try detectDevice()

        if let helperPath = helperExecutablePath() {
            try agent.connect(helperPath: helperPath)
            let output = try agent.list()
            return try parseHelperSnapshot(from: output, usbDeviceName: usbSnapshot.title)
        }

        try requireCommand("mtp-files")
        let folderPaths = loadFolderPaths()
        let filesResult = try runner.run(executable: "mtp-files", arguments: [], timeout: 60)
        let filesOutput = filesResult.combinedOutput
        if indicatesNoMTPDevice(filesOutput) {
            if !folderPaths.isEmpty {
                let items = parseFolders(from: folderPaths).sorted {
                    $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath) == .orderedAscending
                }
                let info = parseDeviceInfo(from: filesOutput, usbDeviceName: usbSnapshot.title)
                return KindleLibrarySnapshot(
                    deviceInfo: info,
                    items: items,
                    rawDeviceOutput: "",
                    rawFilesOutput: filesOutput
                )
            }
            throw MTPServiceError.noDeviceDetected(friendlyMTPFailureMessage(for: filesOutput))
        }

        let items = parseFolders(from: folderPaths) + parseFiles(from: filesOutput, folderPaths: folderPaths)
        let sortedItems = items.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .folder
            }
            return lhs.displayPath.localizedCaseInsensitiveCompare(rhs.displayPath) == .orderedAscending
        }
        let info = parseDeviceInfo(from: filesOutput, usbDeviceName: usbSnapshot.title)

        return KindleLibrarySnapshot(
            deviceInfo: info,
            items: sortedItems,
            rawDeviceOutput: "",
            rawFilesOutput: filesOutput
        )
    }

    func transfer(_ urls: [URL], to folder: String = "/documents") throws -> TransferBatchResult {
        guard checkDependency() else {
            throw MTPServiceError.libMTPMissing
        }

        let targetFolders = transferCandidateFolders(for: folder)
        if let helperPath = helperExecutablePath() {
            return transferWithAgent(urls, targetFolder: targetFolders[0], helperPath: helperPath)
        }

        var successes: [URL] = []
        var failures: [TransferFailure] = []

        for url in urls {
            do {
                try send(url, targetFolders: targetFolders)
                successes.append(url)
            } catch {
                failures.append(TransferFailure(url: url, reason: error.localizedDescription))
            }
        }

        return TransferBatchResult(successes: successes, failures: failures)
    }

    private func transferWithAgent(_ urls: [URL], targetFolder: String, helperPath: String) -> TransferBatchResult {
        var successes: [URL] = []
        var failures: [TransferFailure] = []

        do {
            try agent.connect(helperPath: helperPath)
        } catch {
            return TransferBatchResult(
                successes: [],
                failures: urls.map { TransferFailure(url: $0, reason: error.localizedDescription) }
            )
        }

        for url in urls {
            do {
                try agent.send(localPath: url.path(percentEncoded: false), folder: targetFolder)
                successes.append(url)
            } catch {
                failures.append(TransferFailure(url: url, reason: error.localizedDescription))
            }
        }

        return TransferBatchResult(successes: successes, failures: failures)
    }

    private func transferCandidateFolders(for folder: String) -> [String] {
        let normalized = KindleItem.normalizedPath(folder)
        guard normalized.localizedCaseInsensitiveCompare("/documents") == .orderedSame else {
            return [normalized]
        }
        return candidateFolders
    }

    private func send(_ url: URL, targetFolders: [String]) throws {
        guard url.isFileURL else {
            throw MTPServiceError.transferFailed("只支持本地文件：\(url.lastPathComponent)")
        }

        let filePath = url.path(percentEncoded: false)
        var lastError = "未知错误"

        for folder in targetFolders {
            let result = try runner.run(executable: "mtp-sendfile", arguments: [filePath, folder], timeout: 180)
            let output = result.combinedOutput

            if result.exitCode == 0 && !output.localizedCaseInsensitiveContains("error sending file") {
                return
            }

            lastError = output.isEmpty ? "传输失败，命令退出码 \(result.exitCode)" : output
            if !output.localizedCaseInsensitiveContains("Parent folder could not be found") {
                break
            }
        }

        throw MTPServiceError.transferFailed(lastError)
    }

    private func requireCommand(_ executable: String) throws {
        guard runner.commandExists(executable) else {
            throw MTPServiceError.commandMissing(executable)
        }
    }

    private func helperExecutablePath() -> String? {
        let bundle = Bundle.main
        let candidates: [String?] = [
            bundle.path(forAuxiliaryExecutable: "mtp-kindle-ls"),
            bundle.url(forResource: "mtp-kindle-ls", withExtension: nil)?.path,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/mtp-kindle-ls")
                .path
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private func parseHelperSnapshot(from output: String, usbDeviceName: String) throws -> KindleLibrarySnapshot {
        var items: [KindleItem] = []
        var capacity: Int64?
        var free: Int64?
        var errors: [String] = []

        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let recordType = fields.first else { continue }

            switch recordType {
            case "STORAGE":
                if fields.count >= 5 {
                    if capacity == nil {
                        capacity = int64FromUnsignedText(fields[3])
                    }
                    if free == nil {
                        free = int64FromUnsignedText(fields[4])
                    }
                }
            case "ITEM":
                if let item = parseHelperItem(fields) {
                    items.append(item)
                }
            case "ERROR":
                if fields.count >= 3 {
                    errors.append(unescapeHelperField(fields[2]))
                }
            default:
                continue
            }
        }

        if items.isEmpty && !errors.isEmpty {
            throw MTPServiceError.noDeviceDetected(friendlyMTPFailureMessage(for: errors.joined(separator: "\n")))
        }

        let sortedItems = items.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .folder
            }
            return lhs.displayPath.localizedCaseInsensitiveCompare(rhs.displayPath) == .orderedAscending
        }

        var info = KindleDeviceInfo()
        info.deviceName = usbDeviceName
        info.model = usbDeviceName
        info.storageDescription = capacity.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        info.freeSpaceDescription = free.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }

        return KindleLibrarySnapshot(
            deviceInfo: info,
            items: sortedItems,
            rawDeviceOutput: "",
            rawFilesOutput: output
        )
    }

    private func parseHelperItem(_ fields: [String]) -> KindleItem? {
        guard fields.count >= 9 else { return nil }

        let kind: KindleItemKind = fields[1] == "folder" ? .folder : .file
        let itemID = fields[2]
        let parentID = UInt64(fields[3])
        let storageID = fields[4]
        let size = int64FromUnsignedText(fields[5])
        let path = unescapeHelperField(fields[6])
        let name = unescapeHelperField(fields[7])
        let fileType = unescapeHelperField(fields[8])

        return KindleItem(
            id: "\(fields[1])-\(storageID)-\(itemID)",
            name: name.isEmpty ? path : name,
            kind: kind,
            sizeBytes: kind == .file ? size : nil,
            parentID: parentID,
            path: path.isEmpty ? nil : path,
            fileType: fileType.isEmpty ? nil : fileType
        )
    }

    private func loadFolderPaths() -> [UInt64: String] {
        guard runner.commandExists("mtp-folders"),
              let result = try? runner.run(executable: "mtp-folders", arguments: [], timeout: 30),
              !indicatesNoMTPDevice(result.combinedOutput) else {
            return [:]
        }

        return parseFolderPaths(from: result.combinedOutput)
    }

    private func parseFolders(from folderPaths: [UInt64: String]) -> [KindleItem] {
        folderPaths.map { id, path in
            KindleItem(
                id: "folder-\(id)",
                name: URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent,
                kind: .folder,
                sizeBytes: nil,
                parentID: nil,
                path: path,
                fileType: nil
            )
        }
    }

    private func parseFiles(from output: String, folderPaths: [UInt64: String]) -> [KindleItem] {
        var records: [String] = []
        var currentRecord: [String] = []

        for line in output.components(separatedBy: .newlines) {
            if value(after: "File ID", in: line) != nil {
                if !currentRecord.isEmpty {
                    records.append(currentRecord.joined(separator: "\n"))
                }
                currentRecord = [line]
            } else if !currentRecord.isEmpty {
                currentRecord.append(line)
            }
        }

        if !currentRecord.isEmpty {
            records.append(currentRecord.joined(separator: "\n"))
        }

        return records.compactMap { record in
            parseFileRecord(record, folderPaths: folderPaths)
        }
    }

    private func parseFileRecord(_ record: String, folderPaths: [UInt64: String]) -> KindleItem? {
        let lines = record.components(separatedBy: .newlines)
        guard let firstLine = lines.first,
              let rawID = value(after: "File ID", in: firstLine),
              let id = UInt64(rawID.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) else {
            return nil
        }

        let filename = field(named: "Filename", in: lines)
            ?? field(named: "File name", in: lines)
        guard let filename, !filename.isEmpty else { return nil }

        let parentID = field(named: "Parent ID", in: lines).flatMap(UInt64.init)
        let size = field(named: "File size", in: lines)
            .flatMap { Int64($0.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) }
        let fileType = field(named: "Filetype", in: lines)
            ?? field(named: "File type", in: lines)

        let folderPath = parentID.flatMap { folderPaths[$0] }
        let path = folderPath.map { folder in
            folder.hasSuffix("/") ? "\(folder)\(filename)" : "\(folder)/\(filename)"
        }

        return KindleItem(
            id: "file-\(id)",
            name: filename,
            kind: .file,
            sizeBytes: size,
            parentID: parentID,
            path: path,
            fileType: fileType
        )
    }

    private func parseFolderPaths(from output: String) -> [UInt64: String] {
        var paths: [UInt64: String] = [:]
        var stack: [(indent: Int, id: UInt64, name: String)] = []

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = parseFolderLine(rawLine), !line.isEmpty else { continue }

            while let last = stack.last, last.indent >= match.indent {
                stack.removeLast()
            }

            stack.append((match.indent, match.id, match.name))
            let components = stack
                .map(\.name)
                .filter { !$0.isEmpty && $0 != "/" }
            paths[match.id] = "/" + components.joined(separator: "/")
        }

        return paths
    }

    private func parseFolderLine(_ line: String) -> (indent: Int, id: UInt64, name: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let colonIndex = trimmed.firstIndex(of: ":") else { return nil }

        let idText = trimmed[..<colonIndex].trimmingCharacters(in: .whitespaces)
        guard let id = UInt64(idText) else { return nil }

        let nameStart = trimmed.index(after: colonIndex)
        let name = trimmed[nameStart...].trimmingCharacters(in: .whitespaces)
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        return (indent, id, name)
    }

    private func parseDeviceInfo(from output: String, usbDeviceName: String) -> KindleDeviceInfo {
        let storageValues = parseStorageValues(from: output)
        var info = KindleDeviceInfo()

        info.deviceName = usbDeviceName
        info.model = usbDeviceName
        info.storageDescription = storageValues.capacity.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        info.freeSpaceDescription = storageValues.free.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }

        return info
    }

    private func parseStorageValues(from output: String) -> (capacity: Int64?, free: Int64?) {
        let lines = output.components(separatedBy: .newlines)
        let capacity = value(afterAnyOf: ["MaxCapacity", "Max Capacity", "Storage Max Capacity"], in: lines)
            .flatMap(bytesFromText)
        let free = value(afterAnyOf: ["FreeSpaceInBytes", "Free Space in Bytes", "Storage Free Space"], in: lines)
            .flatMap(bytesFromText)
        return (capacity, free)
    }

    private func field(named name: String, in lines: [String]) -> String? {
        value(afterAnyOf: [name], in: lines)
    }

    private func value(afterAnyOf keys: [String], in lines: [String]) -> String? {
        for line in lines {
            for key in keys {
                if let value = value(after: key, in: line) {
                    return value
                }
            }
        }
        return nil
    }

    private func value(after key: String, in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.localizedCaseInsensitiveContains(key),
              let separator = trimmed.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
            return nil
        }

        let label = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
        guard label.localizedCaseInsensitiveContains(key) else { return nil }

        let valueStart = trimmed.index(after: separator)
        let value = trimmed[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func bytesFromText(_ value: String) -> Int64? {
        let digits = value.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int64(digits)
    }

    private func int64FromUnsignedText(_ value: String) -> Int64? {
        guard let unsigned = UInt64(value), unsigned <= UInt64(Int64.max) else {
            return nil
        }
        return Int64(unsigned)
    }

    private func unescapeHelperField(_ value: String) -> String {
        var output = ""
        var iterator = value.makeIterator()

        while let character = iterator.next() {
            guard character == "\\" else {
                output.append(character)
                continue
            }

            guard let escaped = iterator.next() else {
                output.append(character)
                break
            }

            switch escaped {
            case "t":
                output.append("\t")
            case "n":
                output.append("\n")
            case "r":
                output.append("\r")
            case "\\":
                output.append("\\")
            default:
                output.append(escaped)
            }
        }

        return output
    }

    private func indicatesNoMTPDevice(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("No raw devices found")
            || output.localizedCaseInsensitiveContains("No Devices have been found")
            || output.localizedCaseInsensitiveContains("no devices found")
            || output.localizedCaseInsensitiveContains("No devices.")
            || output.localizedCaseInsensitiveContains("Unable to open raw device")
            || output.localizedCaseInsensitiveContains("Unable to initialize device")
    }

    private func friendlyMTPFailureMessage(for output: String) -> String {
        if output.localizedCaseInsensitiveContains("Unable to open raw device")
            || output.localizedCaseInsensitiveContains("Unable to initialize device")
            || output.localizedCaseInsensitiveContains("libusb_claim_interface") {
            return "无法打开 Kindle 的 MTP 文件列表。请先完全退出 OpenMTP 或其他正在连接 Kindle 的软件，然后拔插 Kindle 后重新连接。"
        }

        return "没有读取到 Kindle 文件列表。请确认 Kindle 停留在 USB 连接状态，并且 USB 线支持数据传输。"
    }

    private func findKindleName(in ioregPlist: String) -> String? {
        guard let data = ioregPlist.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }

        return findUSBDeviceName(in: root)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func findUSBDeviceName(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            let productName = dictionary["USB Product Name"] as? String
                ?? dictionary["kUSBProductString"] as? String
                ?? dictionary["IORegistryEntryName"] as? String
            let vendorName = dictionary["USB Vendor Name"] as? String
                ?? dictionary["kUSBVendorString"] as? String

            if [productName, vendorName].compactMap({ $0 }).contains(where: isKindleDescriptor) {
                return productName ?? vendorName ?? "Kindle"
            }

            for child in dictionary.values {
                if let match = findUSBDeviceName(in: child) {
                    return match
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let match = findUSBDeviceName(in: child) {
                    return match
                }
            }
        }

        return nil
    }

    private func isKindleDescriptor(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("kindle")
            || value.localizedCaseInsensitiveContains("amazon")
    }
}
