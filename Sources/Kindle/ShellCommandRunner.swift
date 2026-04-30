import Foundation

struct CommandResult: Sendable {
    let executable: String
    let arguments: [String]
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var combinedOutput: String {
        let pieces = [standardOutput, standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pieces.joined(separator: "\n")
    }
}

enum ShellCommandError: Error, LocalizedError, Sendable {
    case executableNotFound(String)
    case launchFailed(String)
    case timedOut(String, TimeInterval)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "找不到命令：\(name)"
        case .launchFailed(let message):
            return message
        case .timedOut(let name, let timeout):
            return "命令超时：\(name) 运行超过 \(Int(timeout)) 秒。"
        }
    }
}

struct ShellCommandRunner: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval = 30) throws -> CommandResult {
        let resolvedExecutable = try resolveExecutable(named: executable)

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: resolvedExecutable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminationSemaphore.signal()
        }

        let envPath = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            ProcessInfo.processInfo.environment["PATH"] ?? ""
        ]
            .filter { !$0.isEmpty }
            .joined(separator: ":")

        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": envPath]) { _, new in new }

        do {
            try process.run()
        } catch {
            throw ShellCommandError.launchFailed("无法启动命令 \(executable): \(error.localizedDescription)")
        }

        let stdoutBuffer = ProcessOutputBuffer()
        let stderrBuffer = ProcessOutputBuffer()
        let pipeReadGroup = DispatchGroup()

        pipeReadGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBuffer.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
            pipeReadGroup.leave()
        }

        pipeReadGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBuffer.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
            pipeReadGroup.leave()
        }

        if terminationSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            pipeReadGroup.wait()
            throw ShellCommandError.timedOut(executable, timeout)
        }

        pipeReadGroup.wait()

        let stdout = String(data: stdoutBuffer.value(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrBuffer.value(), encoding: .utf8) ?? ""

        return CommandResult(
            executable: resolvedExecutable,
            arguments: arguments,
            exitCode: process.terminationStatus,
            standardOutput: stdout,
            standardError: stderr
        )
    }

    func commandExists(_ executable: String) -> Bool {
        (try? resolveExecutable(named: executable)) != nil
    }

    private func resolveExecutable(named executable: String) throws -> String {
        if executable.contains("/") {
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                throw ShellCommandError.executableNotFound(executable)
            }
            return executable
        }

        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)

        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executable).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        throw ShellCommandError.executableNotFound(executable)
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        let current = data
        lock.unlock()
        return current
    }
}
