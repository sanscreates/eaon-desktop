import Foundation

/// Executes a workspace script locally and streams its output into the
/// panel's console — the "run" half of the agentic coding workspace.
///
/// The workspace's files are written to a throwaway temp folder and the
/// entry file is run there with the user's own tools (`/usr/bin/env
/// python3` etc.), so imports/reads between the generated files resolve
/// exactly as they would in a real project folder. Only ever started by the
/// user clicking Run — never automatically.
@MainActor
@Observable
final class WorkspaceRunner {
    static let shared = WorkspaceRunner()
    private init() {}

    enum ChunkKind {
        case command, stdout, stderr, status
    }

    /// A run of console output. Consecutive output of the same kind is
    /// coalesced into one chunk so the array stays tiny no matter how chatty
    /// the process is.
    struct ConsoleChunk: Identifiable, Equatable {
        let id = UUID()
        let kind: ChunkKind
        var text: String
    }

    private(set) var chunks: [ConsoleChunk] = []
    private(set) var isRunning = false

    private var process: Process?
    private var totalOutputChars = 0
    /// Runaway-print guard: past this the process is killed rather than
    /// letting an infinite print loop eat the UI.
    private let outputCap = 200_000

    // Agent-run bookkeeping: the loop awaits completion, so the exit code is
    // delivered through a continuation and stdout/stderr are also collected
    // into a plain string for the tool result.
    private var agentContinuation: CheckedContinuation<Int32, Never>?
    private var agentCollectedOutput: String?
    private var agentTimedOut = false
    private var timeoutTask: Task<Void, Never>?

    // MARK: - Language support

    /// Which tool runs a given file, by extension. Compiled languages that
    /// need a build step (C, Java…) are deliberately absent — this is a
    /// script runner, not a build system.
    static func command(forPath path: String) -> (tool: String, extraArgs: [String])? {
        switch (path as NSString).pathExtension.lowercased() {
        case "py": return ("python3", [])
        case "js", "mjs", "cjs": return ("node", [])
        case "rb": return ("ruby", [])
        case "php": return ("php", [])
        case "swift": return ("swift", [])
        case "sh", "bash": return ("bash", [])
        case "zsh": return ("zsh", [])
        case "pl": return ("perl", [])
        case "lua": return ("lua", [])
        case "go": return ("go", ["run"])
        default: return nil
        }
    }

    static func isRunnable(_ path: String) -> Bool {
        command(forPath: path) != nil
    }

    // MARK: - Run / stop

    func run(files: [WorkspaceFile], entry: WorkspaceFile, workspaceKey: String) {
        guard let cmd = Self.command(forPath: entry.path) else { return }
        teardownQuietly()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EaonDesktopRun", isDirectory: true)
            .appendingPathComponent(workspaceKey, isDirectory: true)

        chunks = []
        totalOutputChars = 0

        do {
            try? FileManager.default.removeItem(at: root)
            for file in files {
                let destination = root.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try file.content.write(to: destination, atomically: true, encoding: .utf8)
            }
        } catch {
            append(.stderr, "Could not prepare the project files: \(error.localizedDescription)\n")
            return
        }

        let commandLine = ([cmd.tool] + cmd.extraArgs + [entry.path]).joined(separator: " ")
        append(.command, "$ \(commandLine)\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [cmd.tool] + cmd.extraArgs + [entry.path]
        process.currentDirectoryURL = root

        // GUI apps get a bare PATH — add the places runtimes actually live
        // (Homebrew on both architectures) so `node`/`python3` resolve the
        // same as they would in the user's terminal.
        var environment = ProcessInfo.processInfo.environment
        let basePath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = basePath + ":/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // No stdin: a program that waits for keyboard input sees EOF instead
        // of hanging forever on input that can never arrive.
        process.standardInput = FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.append(.stdout, text) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.append(.stderr, text) }
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.finish(finished) }
        }

        do {
            try process.run()
            self.process = process
            isRunning = true
        } catch {
            append(.stderr, "Could not start \(cmd.tool): \(error.localizedDescription)\n")
            append(.status, statusLine("Failed to start."), force: true)
        }
    }

    func stop() {
        guard let process, isRunning else { return }
        process.terminate()
    }

    func clear() {
        guard !isRunning else { return }
        chunks = []
        totalOutputChars = 0
    }

    /// Adds a line to the console without running anything — the agent's
    /// activity feed (edits, reads, preview errors, loop notices).
    func note(_ text: String, kind: ChunkKind) {
        append(kind, text, force: true)
    }

    // MARK: - Agent runs

    struct AgentRunOutcome {
        let exitCode: Int32
        let output: String
        let timedOut: Bool
    }

    /// Agent-initiated run: streams into the console exactly like a user Run,
    /// but awaits completion, enforces a timeout, and returns the exit code
    /// plus the collected output for the tool result. Cancelling the agent
    /// task terminates the process.
    func agentRun(
        files: [WorkspaceFile],
        entry: WorkspaceFile,
        workspaceKey: String,
        timeout: TimeInterval
    ) async -> AgentRunOutcome {
        guard Self.command(forPath: entry.path) != nil else {
            return AgentRunOutcome(exitCode: -1, output: "unsupported file type", timedOut: false)
        }

        agentCollectedOutput = ""
        agentTimedOut = false
        run(files: files, entry: entry, workspaceKey: workspaceKey)

        guard isRunning, let launched = process else {
            let collected = agentCollectedOutput ?? ""
            agentCollectedOutput = nil
            return AgentRunOutcome(
                exitCode: -1,
                output: collected.isEmpty ? "the process failed to start" : collected,
                timedOut: false
            )
        }

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, self.process === launched, self.isRunning else { return }
            self.agentTimedOut = true
            self.note("● Timed out after \(Int(timeout))s — stopping.\n", kind: .status)
            launched.terminate()
        }

        let exitCode = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                agentContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }

        let collected = agentCollectedOutput ?? ""
        agentCollectedOutput = nil
        return AgentRunOutcome(exitCode: exitCode, output: collected, timedOut: agentTimedOut)
    }

    // MARK: - Internals

    private func finish(_ finished: Process) {
        guard finished === process else { return }
        (finished.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (finished.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil

        if finished.terminationReason == .uncaughtSignal {
            append(.status, statusLine("Stopped."), force: true)
        } else if finished.terminationStatus == 0 {
            append(.status, statusLine("Finished (exit code 0)."), force: true)
        } else if finished.terminationStatus == 127 {
            append(.status, statusLine("Exit code 127 — that language's runtime isn't installed on this Mac."), force: true)
        } else {
            append(.status, statusLine("Exited with code \(finished.terminationStatus)."), force: true)
        }

        process = nil
        isRunning = false
        timeoutTask?.cancel()
        timeoutTask = nil
        if let continuation = agentContinuation {
            agentContinuation = nil
            continuation.resume(returning: finished.terminationStatus)
        }
    }

    /// Silently kills any in-flight run without emitting its status line —
    /// used when a new run replaces an old one so the fresh console doesn't
    /// open with a stale "Stopped." from the previous process.
    private func teardownQuietly() {
        timeoutTask?.cancel()
        timeoutTask = nil
        // An agent await must never be left hanging — if something replaces
        // its process (e.g. the user clicks Run mid-loop), resolve it.
        if let continuation = agentContinuation {
            agentContinuation = nil
            continuation.resume(returning: -1)
        }
        guard let process else { return }
        process.terminationHandler = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        self.process = nil
        isRunning = false
    }

    private func statusLine(_ text: String) -> String {
        (chunks.isEmpty ? "" : "\n") + "● \(text)\n"
    }

    private func append(_ kind: ChunkKind, _ text: String, force: Bool = false) {
        if !force {
            guard totalOutputChars < outputCap else { return }
            totalOutputChars += text.count
            if totalOutputChars >= outputCap {
                appendRaw(kind, text)
                appendRaw(.status, "\n● Output truncated after \(outputCap / 1000)k characters — stopping the process.\n")
                process?.terminate()
                return
            }
        }
        appendRaw(kind, text)
    }

    private func appendRaw(_ kind: ChunkKind, _ text: String) {
        if kind == .stdout || kind == .stderr {
            agentCollectedOutput? += text
        }
        if let lastIndex = chunks.indices.last, chunks[lastIndex].kind == kind {
            chunks[lastIndex].text += text
        } else {
            chunks.append(ConsoleChunk(kind: kind, text: text))
        }
    }
}
