import Foundation

struct CommandResult {
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

enum ShellCommandError: Error, LocalizedError {
    case executableNotFound(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "找不到命令：\(name)"
        case .launchFailed(let message):
            return message
        }
    }
}

struct ShellCommandRunner {
    func run(executable: String, arguments: [String]) throws -> CommandResult {
        let resolvedExecutable = try resolveExecutable(named: executable)

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: resolvedExecutable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

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

        process.waitUntilExit()

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

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
