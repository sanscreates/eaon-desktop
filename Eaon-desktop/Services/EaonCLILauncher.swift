import Foundation

/// Locates a runnable `node dist/cli.js` for the already-built `eaon-cli`
/// package and a `node` binary to run it with, so Eaon Code's embedded
/// terminal (see `EmbeddedTerminalView`) can launch the real CLI instead of
/// a plain shell. Deliberately tolerant: every path here is a best-effort
/// guess at where a dev checkout or a future packaged copy would live —
/// `resolve()` returns nil rather than throwing when nothing is found, and
/// the terminal view falls back to the user's login shell.
enum EaonCLILauncher {
    struct Launch {
        let executable: String
        let arguments: [String]
        let environment: [String]?
        let currentDirectory: String?
    }

    /// Common install locations for a `node` binary, checked in order
    /// before falling back to whatever `PATH` resolves at runtime — GUI
    /// apps on macOS don't inherit the user's shell `PATH`, so `which`
    /// alone isn't reliable here (the actual failure mode this guards
    /// against, seen with nvm/homebrew installs that never launch the app
    /// through a shell).
    private static let commonNodePaths = [
        "/opt/homebrew/bin/node",
        "/usr/local/bin/node",
        NSHomeDirectory() + "/.local/bin/node",
        NSHomeDirectory() + "/.nvm/current/bin/node",
        "/usr/bin/node",
    ]

    private static func findNode() -> String? {
        let fm = FileManager.default
        for path in commonNodePaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: ask a real login shell to resolve it, which picks
        // up nvm/asdf-style shims a fixed path list can't anticipate.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v node"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let output, !output.isEmpty, fm.isExecutableFile(atPath: output) else { return nil }
        return output
    }

    /// Where `dist/cli.js` might live: bundled inside the app (a future
    /// packaged copy, dropped under Resources at build time) or — for this
    /// dev-checkout phase — the `eaon-cli` sibling directory next to this
    /// Swift package's own source, resolved from the source file's own
    /// on-disk path so it works from an Xcode/`swift build` run without
    /// hardcoding the developer's home directory.
    private static func findCLIEntryPoint() -> String? {
        let fm = FileManager.default
        if let bundled = Bundle.main.url(forResource: "cli", withExtension: "js", subdirectory: "eaon-cli/dist")?.path,
           fm.fileExists(atPath: bundled) {
            return bundled
        }
        // #filePath is this source file's own on-disk location at compile
        // time — walking up from Eaon-desktop/Services/ to the repo root
        // and across to eaon-cli/dist/cli.js finds the dev build without
        // any user-specific path.
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // Eaon-desktop
            .deletingLastPathComponent() // repo root
        let devEntryPoint = repoRoot.appendingPathComponent("eaon-cli/dist/cli.js").path
        if fm.fileExists(atPath: devEntryPoint) {
            return devEntryPoint
        }
        return nil
    }

    /// Resolves everything needed to launch eaon-cli in a terminal, or nil
    /// when either `node` or the CLI's built entry point can't be found.
    static func resolve() -> Launch? {
        guard let node = findNode(), let entryPoint = findCLIEntryPoint() else { return nil }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["TERM"] = "xterm-256color"
        return Launch(
            executable: node,
            arguments: [entryPoint],
            environment: env.map { "\($0.key)=\($0.value)" },
            currentDirectory: NSHomeDirectory()
        )
    }

    // MARK: - Status / settings surface

    /// Everything the Settings UI needs to report on and control the CLI —
    /// whether it's runnable right now, where it lives, and its version.
    struct Status {
        /// The resolved `node` binary, or nil if none was found.
        let nodePath: String?
        /// The built `dist/cli.js`, or nil if the CLI hasn't been built.
        let entryPoint: String?
        /// The `eaon-cli` project directory (parent of `dist/`), or nil.
        let cliDirectory: String?
        /// The CLI's package version (read from its `package.json`), or nil.
        let version: String?

        /// Both halves present → Eaon Code can launch the real CLI.
        var isReady: Bool { nodePath != nil && entryPoint != nil }
    }

    /// Blocking (spawns a login shell to resolve `node` as a last resort) —
    /// call off the main thread. Used by the Settings CLI panel.
    static func status() -> Status {
        let node = findNode()
        let entryPoint = findCLIEntryPoint()
        let directory = cliDirectory(fromEntryPoint: entryPoint)
        return Status(
            nodePath: node,
            entryPoint: entryPoint,
            cliDirectory: directory,
            version: directory.flatMap(readVersion(inDirectory:))
        )
    }

    /// Where the CLI's own config + sessions live (`~/.eaon/cli/`) — the same
    /// path the Node CLI's `platform.ts configDir()` computes, so the app and
    /// the CLI point at the exact same file.
    static var configDirectory: String {
        NSHomeDirectory() + "/.eaon/cli"
    }

    static var configFilePath: String {
        configDirectory + "/config.json"
    }

    /// The `eaon-cli` directory: prefer walking up from a resolved entry
    /// point (`.../eaon-cli/dist/cli.js` → `.../eaon-cli`), else fall back to
    /// the dev-checkout location next to this source file so the Settings
    /// panel can still show "how to build it" before a first build exists.
    private static func cliDirectory(fromEntryPoint entryPoint: String?) -> String? {
        if let entryPoint {
            // .../eaon-cli/dist/cli.js → .../eaon-cli
            let dir = URL(fileURLWithPath: entryPoint)
                .deletingLastPathComponent() // dist
                .deletingLastPathComponent() // eaon-cli
            return dir.path
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // Eaon-desktop
            .deletingLastPathComponent() // repo root
        let devDir = repoRoot.appendingPathComponent("eaon-cli").path
        return FileManager.default.fileExists(atPath: devDir) ? devDir : nil
    }

    private static func readVersion(inDirectory directory: String) -> String? {
        let packageJSON = directory + "/package.json"
        guard let data = FileManager.default.contents(atPath: packageJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else { return nil }
        return version
    }
}
