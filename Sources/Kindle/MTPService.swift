import Foundation

enum MTPServiceError: Error, LocalizedError {
    case libMTPMissing
    case noDeviceDetected(String)
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .libMTPMissing:
            return "未检测到 libmtp。请先执行 `brew install libmtp`。"
        case .noDeviceDetected(let output):
            return output.isEmpty ? "没有检测到已连接的 Kindle。" : output
        case .transferFailed(let message):
            return message
        }
    }
}

struct MTPService {
    private let runner = ShellCommandRunner()
    private let candidateFolders = ["/documents", "/Documents"]

    func checkDependency() -> Bool {
        runner.commandExists("mtp-detect") && runner.commandExists("mtp-sendfile")
    }

    func detectDevice() throws -> DeviceSnapshot {
        guard checkDependency() else {
            throw MTPServiceError.libMTPMissing
        }

        let result = try runner.run(executable: "mtp-detect", arguments: [])
        let output = result.combinedOutput

        if output.localizedCaseInsensitiveContains("No raw devices found")
            || output.localizedCaseInsensitiveContains("no devices found")
            || output.localizedCaseInsensitiveContains("No devices.") {
            throw MTPServiceError.noDeviceDetected(output)
        }

        let title = output
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.contains("Device:") || $0.contains("(MTP)") || $0.contains("Kindle") })
            ?? "已检测到 MTP 设备"

        return DeviceSnapshot(title: title.trimmingCharacters(in: .whitespacesAndNewlines), rawOutput: output)
    }

    func transfer(_ urls: [URL]) throws -> TransferBatchResult {
        guard checkDependency() else {
            throw MTPServiceError.libMTPMissing
        }

        _ = try detectDevice()

        var successes: [URL] = []
        var failures: [(url: URL, reason: String)] = []

        for url in urls {
            do {
                try send(url)
                successes.append(url)
            } catch {
                failures.append((url, error.localizedDescription))
            }
        }

        return TransferBatchResult(successes: successes, failures: failures)
    }

    private func send(_ url: URL) throws {
        guard url.isFileURL else {
            throw MTPServiceError.transferFailed("只支持本地文件：\(url.lastPathComponent)")
        }

        let filePath = url.path(percentEncoded: false)
        var lastError = "未知错误"

        for folder in candidateFolders {
            let result = try runner.run(executable: "mtp-sendfile", arguments: [filePath, folder])
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
}
