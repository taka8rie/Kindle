import Foundation

enum MTPAgentError: Error, LocalizedError, Sendable {
    case helperMissing
    case launchFailed(String)
    case notReady(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "找不到 MTP helper。"
        case .launchFailed(let message):
            return message
        case .notReady(let message):
            return message
        case .commandFailed(let message):
            return message
        }
    }
}

final class MTPAgent: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    deinit {
        disconnect()
    }

    func connect(helperPath: String) throws {
        lock.lock()
        defer { lock.unlock() }

        if process?.isRunning == true {
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = ["--agent"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw MTPAgentError.launchFailed("无法启动 MTP 会话：\(error.localizedDescription)")
        }

        DispatchQueue.global(qos: .utility).async {
            _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
        }

        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading

        let hello = try readLine()
        guard hello == "KINDLEAGENT\t1" else {
            disconnect()
            throw MTPAgentError.notReady(cleanErrorMessage(hello))
        }

        while true {
            let line = try readLine()
            if line == "READY" {
                return
            }
            if line.hasPrefix("ERROR\t") {
                disconnect()
                throw MTPAgentError.notReady(cleanErrorMessage(line))
            }
        }
    }

    func list() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        try writeLine("LIST")

        var lines: [String] = []
        while true {
            let line = try readLine()
            lines.append(line)
            if line.hasPrefix("END_LIST") {
                return lines.joined(separator: "\n")
            }
            if line.hasPrefix("ERROR\t") {
                throw MTPAgentError.commandFailed(cleanErrorMessage(line))
            }
        }
    }

    func send(localPath: String, folder: String) throws {
        lock.lock()
        defer { lock.unlock() }

        try writeLine("SEND\t\(Self.escape(localPath))\t\(Self.escape(folder))")

        while true {
            let line = try readLine()
            if line.hasPrefix("SEND_OK\t") {
                return
            }
            if line.hasPrefix("ERROR\t") {
                throw MTPAgentError.commandFailed(cleanErrorMessage(line))
            }
        }
    }

    func disconnect() {
        lock.lock()
        defer { lock.unlock() }

        if process?.isRunning == true {
            try? writeLine("QUIT")
            process?.terminate()
        }

        process = nil
        input = nil
        output = nil
    }

    private func writeLine(_ line: String) throws {
        guard let input else {
            throw MTPAgentError.notReady("MTP 会话尚未连接。")
        }

        guard let data = "\(line)\n".data(using: .utf8) else { return }
        input.write(data)
    }

    private func readLine() throws -> String {
        guard let output else {
            throw MTPAgentError.notReady("MTP 会话尚未连接。")
        }

        var data = Data()
        while true {
            let chunk = output.readData(ofLength: 1)
            if chunk.isEmpty {
                throw MTPAgentError.notReady("MTP 会话已断开。")
            }
            if chunk.first == 10 {
                break
            }
            data.append(chunk)
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            ?? ""
    }

    private func cleanErrorMessage(_ line: String) -> String {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        if fields.count >= 3, fields[0] == "ERROR" {
            return Self.unescape(fields[2])
        }
        return line.isEmpty ? "MTP 会话启动失败。" : line
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static func unescape(_ value: String) -> String {
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
}
