import Foundation

/// Exit status and captured output of one finished command.
public struct CommandResult: Sendable, Hashable {
    public var status: Int32
    public var output: String
    public var errorOutput: String

    public init(status: Int32, output: String, errorOutput: String) {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
    }

    public var succeeded: Bool { status == 0 }

    /// stderr, else stdout, trimmed; what to show when the command failed.
    public var message: String {
        let error = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return error.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : error
    }
}

/// A command that failed to start or exited with a non-zero status.
public struct CommandError: Error, Sendable, Hashable, LocalizedError {
    public var command: String
    public var status: Int32
    public var message: String

    public init(command: String, status: Int32, message: String) {
        self.command = command
        self.status = status
        self.message = message
    }

    public var errorDescription: String? {
        message.isEmpty ? "\(command) failed with exit status \(status)." : message
    }
}

/// Runs fixed system tools with argument arrays (never through a shell) and builds the one
/// administrator invocation CareMyMac uses: `osascript` running `do shell script … with administrator privileges`.
public enum OptimizeCommand {
    public static let osascript = "/usr/bin/osascript"

    /// Runs `executable` with `arguments` on a background thread and waits for it to exit.
    /// Throws `CommandError` only when the executable can't be started; a non-zero exit is a normal result.
    public static func run(_ executable: String, _ arguments: [String]) async throws(CommandError) -> CommandResult {
        let outcome: Result<CommandResult, CommandError> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments))
            }
        }
        return try outcome.get()
    }

    private static func runBlocking(_ executable: String, _ arguments: [String]) -> Result<CommandResult, CommandError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failure(CommandError(command: executable, status: -1, message: error.localizedDescription))
        }
        // Drain both pipes at once so a chatty command can't block on a full pipe buffer.
        let errorData = PipeReader(errors.fileHandleForReading)
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return .success(CommandResult(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self),
            errorOutput: String(decoding: errorData.wait(), as: UTF8.self)
        ))
    }

    // MARK: Administrator commands

    /// One argv joined into a `/bin/sh` command line, quoting only arguments that need it.
    public static func shellCommand(_ argv: [String]) -> String {
        argv.map(shellQuoted).joined(separator: " ")
    }

    /// Several argvs run in order, stopping at the first failure.
    public static func shellCommand(_ commands: [[String]]) -> String {
        commands.map(shellCommand).joined(separator: " && ")
    }

    public static func shellQuoted(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacing("'", with: #"'\''"#) + "'"
    }

    /// AppleScript string literal: backslashes and double quotes escaped.
    public static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }

    /// `osascript` arguments that run `commands` as root after macOS asks for an administrator password.
    public static func administratorArguments(_ commands: [[String]]) -> [String] {
        ["-e", "do shell script \(appleScriptString(shellCommand(commands))) with administrator privileges"]
    }

    /// True when `osascript` failed because the user clicked Cancel in the password dialog (error -128).
    public static func isUserCancel(_ result: CommandResult) -> Bool {
        !result.succeeded && result.errorOutput.contains("(-128)")
    }

    /// The readable part of an `osascript` error: "0:98: execution error: Some text (1)" becomes "Some text".
    public static func scriptErrorMessage(_ result: CommandResult) -> String {
        var message = result.message
        if let range = message.range(of: "execution error: ") {
            message = String(message[range.upperBound...])
        }
        if message.hasSuffix(")"), let open = message.lastIndex(of: "("),
           Int(message[message.index(after: open)..<message.index(before: message.endIndex)]) != nil {
            message = String(message[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return message
    }
}

/// Reads a pipe to EOF on its own thread.
private final class PipeReader: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            data = handle.readDataToEndOfFile()
            done.signal()
        }
    }

    func wait() -> Data {
        done.wait()
        return data
    }
}
