import Foundation

// MARK: - Workspace file

/// One file the model has created in the current conversation's code
/// workspace. Workspace contents are always *derived* from the assistant
/// messages themselves (re-parsed on load), so there's no separate persisted
/// store that could drift out of sync with the transcript.
struct WorkspaceFile: Identifiable, Equatable {
    var path: String
    var language: String?
    var content: String
    /// False while this file's closing fence hasn't streamed in yet.
    var isComplete: Bool = true

    var id: String { path }

    var fileName: String { (path as NSString).lastPathComponent }

    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }

    var lineCount: Int {
        content.isEmpty ? 0 : content.components(separatedBy: "\n").count
    }
}

// MARK: - Parser

/// Extracts workspace files from assistant text. The model marks a file by
/// putting a `file="path"` attribute on the opening code fence:
///
///     ```html file="index.html"
///     ...entire file...
///     ```
///
/// Plain fences (no file attribute) are left alone — they stay ordinary chat
/// code blocks.
enum WorkspaceParser {
    /// The instruction that turns any chat model into the workspace's coding
    /// agent. Sent as a system message with every request; it scopes itself
    /// to code-project asks so ordinary conversation is unaffected. The tool
    /// protocol is plain fenced-text (not native API tool-calling) so it
    /// works identically over Aqua and every BYOK wire format.
    static let systemInstruction = """
    You are the coding agent inside Eaon, a desktop app with a live code workspace panel beside the chat: a file explorer, an editor, a console, and a browser preview for websites.

    ENVIRONMENT
    - Files you create appear instantly in the workspace. Websites render in a live preview: the entry point must be index.html, and files must reference each other with relative paths (e.g. <link rel="stylesheet" href="css/style.css">).
    - Scripts run locally on the user's Mac with these runtimes only: python3, node, swift, ruby, php, bash/zsh, perl, lua, go run. STANDARD LIBRARY ONLY — you cannot install packages (no pip, no npm install). No servers, no GUIs: programs get EOF on stdin, must finish on their own, and are killed after 60 seconds.

    TOOLS — each is a fenced code block in your reply:

    1. Create or overwrite a file — a normal fence with a file attribute, containing the COMPLETE file:
    ```html file="index.html"
    <!doctype html>
    ...entire file, first line to last...
    ```

    2. Edit part of an existing file (preferred for small changes — don't rewrite big files):
    ```aqua:edit file="src/app.js"
    <<<<<<< SEARCH
    exact existing lines to find
    =======
    what to replace them with
    >>>>>>> REPLACE
    ```
    The SEARCH text must match the file exactly and appear exactly once.

    3. Run a script file (websites just preview — never "run" an .html file):
    ```aqua:run file="main.py"
    ```

    4. Read a file back:
    ```aqua:read file="main.py"
    ```

    5. List all files:
    ```aqua:ls
    ```

    After your reply, any aqua:run / aqua:edit / aqua:read / aqua:ls tools execute automatically and their results come back to you in a message beginning "[Tool results". You then continue — this loops until you reply with no tools.

    WORKFLOW for coding requests
    1. One short paragraph saying what you'll build. No long plans.
    2. Write ALL the files, complete from first line to last — never "rest unchanged", never placeholder comments.
    3. Scripts: run the entry file with aqua:run, read the result, and if it failed, fix the file (aqua:edit or a full rewrite) and run again — iterate until it exits cleanly. Websites: skip running; they preview automatically.
    4. Finish with a 1–3 sentence summary.

    Use forward slashes for folders (file="css/style.css"). To change a file you already made, prefer aqua:edit; re-emitting the full file with the same path also works.
    For anything that is NOT a coding request — conversation, questions, short snippets meant to be read inline — reply normally, with NO file attributes and NO aqua: blocks.
    """

    /// Cheap pre-check so the full line scan doesn't run on every stream tick
    /// of an ordinary prose reply.
    static func mightContainFiles(_ text: String) -> Bool {
        guard text.contains("```") else { return false }
        return text.contains("file=") || text.contains("path=")
            || text.contains("filename=") || text.contains("aqua:")
    }

    /// The exact search/replace of an `aqua:edit` block, Aider-style.
    struct EditPayload: Equatable {
        let search: String
        let replace: String
    }

    /// Everything the agent can express in a reply, in the order it appears.
    /// Writes/edits drive the derived workspace; run/read/list are executed
    /// by the agent loop after the reply finishes streaming.
    enum Event: Equatable {
        case write(WorkspaceFile)
        /// `payload` is nil while the block is malformed or still streaming —
        /// derivation skips it, and the loop reports the malformation back.
        case edit(path: String, payload: EditPayload?)
        case run(path: String?)
        case read(path: String?)
        case list
    }

    /// Single line-scan state machine over one message's text. A file block
    /// missing its closing fence (mid-stream) yields `isComplete == false`;
    /// incomplete run/read/ls blocks are dropped entirely so a half-streamed
    /// tool is never acted on.
    static func events(from text: String) -> [Event] {
        enum Mode {
            case outside
            case plainFence
            case file(path: String, language: String?)
            case tool(kind: String, path: String?)
        }

        var events: [Event] = []
        var mode = Mode.outside
        var bodyLines: [String] = []

        func closeBlock(complete: Bool) {
            switch mode {
            case .file(let path, let language):
                events.append(.write(WorkspaceFile(
                    path: path,
                    language: language,
                    content: bodyLines.joined(separator: "\n"),
                    isComplete: complete
                )))
            case .tool(let kind, let path):
                switch kind {
                case "edit":
                    if let path {
                        events.append(.edit(path: path, payload: complete ? parseEditPayload(bodyLines) : nil))
                    }
                case "run":
                    if complete { events.append(.run(path: path)) }
                case "read":
                    if complete { events.append(.read(path: path)) }
                case "ls", "list":
                    if complete { events.append(.list) }
                case "write":
                    // Not documented, but a natural thing for a model to try.
                    if let path {
                        events.append(.write(WorkspaceFile(
                            path: path,
                            language: nil,
                            content: bodyLines.joined(separator: "\n"),
                            isComplete: complete
                        )))
                    }
                default:
                    break
                }
            case .outside, .plainFence:
                break
            }
            bodyLines = []
            mode = .outside
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            switch mode {
            case .file, .tool:
                if trimmed == "```" {
                    closeBlock(complete: true)
                } else {
                    bodyLines.append(line)
                }
            case .plainFence:
                if trimmed == "```" { mode = .outside }
            case .outside:
                guard trimmed.hasPrefix("```") else { continue }
                let info = fenceInfo(from: String(trimmed.dropFirst(3)))
                if let language = info.language, language.hasPrefix("aqua:") {
                    mode = .tool(kind: String(language.dropFirst(5)), path: info.path)
                    bodyLines = []
                } else if let path = info.path {
                    mode = .file(path: path, language: info.language)
                    bodyLines = []
                } else {
                    // Ordinary code block — skip past it so a stray "file="
                    // in its *contents* can't be mistaken for a fence.
                    mode = .plainFence
                }
            }
        }
        // Text ended mid-block: the stream is still writing it.
        closeBlock(complete: false)
        return events
    }

    /// The whole conversation's workspace, derived by replaying every write
    /// and edit event across the assistant messages in order. A later write
    /// for the same path replaces the content; an edit patches it in place.
    /// Tool-result messages are skipped — a read-back file's contents must
    /// never be re-parsed as new blocks.
    static func files(fromMessages messages: [ChatMessage]) -> [WorkspaceFile] {
        var ordered: [String] = []
        var byPath: [String: WorkspaceFile] = [:]
        for message in messages where !message.isUser && !message.isError && message.isToolResult != true {
            guard mightContainFiles(message.content) else { continue }
            replay(events(from: message.content), ordered: &ordered, byPath: &byPath)
        }
        return ordered.compactMap { byPath[$0] }
    }

    /// Parses one text's events into the files they produce (writes + edits
    /// applied in order) — the single-message view of the same replay.
    static func parse(_ text: String) -> [WorkspaceFile] {
        var ordered: [String] = []
        var byPath: [String: WorkspaceFile] = [:]
        replay(events(from: text), ordered: &ordered, byPath: &byPath)
        return ordered.compactMap { byPath[$0] }
    }

    static func replay(
        _ events: [Event],
        ordered: inout [String],
        byPath: inout [String: WorkspaceFile]
    ) {
        for event in events {
            switch event {
            case .write(let file):
                if byPath[file.path] == nil { ordered.append(file.path) }
                byPath[file.path] = file
            case .edit(let path, let payload):
                guard let payload, var file = byPath[path],
                      case .applied(let newContent) = applyEdit(to: file.content, payload: payload) else { continue }
                file.content = newContent
                file.isComplete = true
                byPath[path] = file
            case .run, .read, .list:
                break
            }
        }
    }

    // MARK: Edits

    enum EditOutcome: Equatable {
        case applied(String)
        case failed(String)
    }

    /// Applies a search/replace edit the same way everywhere (derivation and
    /// the agent loop's result reporting), with str_replace semantics: the
    /// search text must appear exactly once.
    static func applyEdit(to content: String, payload: EditPayload) -> EditOutcome {
        guard !payload.search.isEmpty else {
            return .failed("the SEARCH section is empty")
        }
        let occurrences = content.components(separatedBy: payload.search).count - 1
        if occurrences == 0 {
            return .failed("the SEARCH text was not found in the file — it must match the current contents exactly (check whitespace)")
        }
        if occurrences > 1 {
            return .failed("the SEARCH text appears \(occurrences) times — include more surrounding lines so it matches exactly once")
        }
        return .applied(content.replacingOccurrences(of: payload.search, with: payload.replace))
    }

    /// Extracts the SEARCH/REPLACE sections from an aqua:edit body. Returns
    /// nil when the conflict markers are missing or out of order.
    static func parseEditPayload(_ lines: [String]) -> EditPayload? {
        func isMarker(_ line: String, _ marker: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces) == marker
        }
        guard let searchStart = lines.firstIndex(where: { isMarker($0, "<<<<<<< SEARCH") }) else { return nil }
        guard let divider = lines[(searchStart + 1)...].firstIndex(where: { isMarker($0, "=======") }) else { return nil }
        guard let replaceEnd = lines[(divider + 1)...].firstIndex(where: { isMarker($0, ">>>>>>> REPLACE") }) else { return nil }
        return EditPayload(
            search: lines[(searchStart + 1)..<divider].joined(separator: "\n"),
            replace: lines[(divider + 1)..<replaceEnd].joined(separator: "\n")
        )
    }

    private static let fileAttributeRegex = try! NSRegularExpression(
        pattern: "(?:file|path|filename)\\s*=\\s*(?:\"([^\"]+)\"|'([^']+)'|([^\\s\"']+))",
        options: [.caseInsensitive]
    )

    /// Splits a fence info string like `html file="css/style.css"` into its
    /// language and file path. `path` is nil for a plain code block. Also
    /// accepts path=/filename= and unquoted values, since models vary.
    static func fenceInfo(from info: String?) -> (language: String?, path: String?) {
        guard let info = info?.trimmingCharacters(in: .whitespaces), !info.isEmpty else {
            return (nil, nil)
        }

        var path: String?
        let range = NSRange(info.startIndex..., in: info)
        if let match = fileAttributeRegex.firstMatch(in: info, range: range) {
            for group in 1...3 {
                if let valueRange = Range(match.range(at: group), in: info) {
                    path = sanitizePath(String(info[valueRange]))
                    break
                }
            }
        }

        let language = info
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .first { !$0.contains("=") }?
            .lowercased()

        return (language, path)
    }

    /// Normalizes a model-supplied path so it's always a safe, relative,
    /// forward-slash path — no absolute paths, no `..` escapes.
    private static func sanitizePath(_ raw: String) -> String? {
        let components = raw
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }
}

// MARK: - File tree

/// A nested explorer-tree built from the workspace's flat path list.
struct WorkspaceTreeNode: Identifiable {
    let name: String
    /// Full file path for files; folder path (used as collapse key) for folders.
    let path: String
    let isFolder: Bool
    var children: [WorkspaceTreeNode] = []

    var id: String { (isFolder ? "dir:" : "file:") + path }
}

enum WorkspaceTree {
    static func build(from files: [WorkspaceFile]) -> [WorkspaceTreeNode] {
        nodes(
            for: files.map { ($0.path.split(separator: "/").map(String.init), $0.path) },
            prefix: ""
        )
    }

    private static func nodes(
        for entries: [(components: [String], fullPath: String)],
        prefix: String
    ) -> [WorkspaceTreeNode] {
        var folderEntries: [String: [(components: [String], fullPath: String)]] = [:]
        var folderOrder: [String] = []
        var fileNodes: [WorkspaceTreeNode] = []

        for entry in entries {
            if entry.components.count == 1 {
                fileNodes.append(WorkspaceTreeNode(name: entry.components[0], path: entry.fullPath, isFolder: false))
            } else {
                let head = entry.components[0]
                if folderEntries[head] == nil { folderOrder.append(head) }
                folderEntries[head, default: []].append((Array(entry.components.dropFirst()), entry.fullPath))
            }
        }

        // Folders first (alphabetical), then files in creation order — the
        // same convention VS Code's explorer uses.
        let folderNodes = folderOrder
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { name in
                let folderPath = prefix.isEmpty ? name : prefix + "/" + name
                return WorkspaceTreeNode(
                    name: name,
                    path: folderPath,
                    isFolder: true,
                    children: nodes(for: folderEntries[name] ?? [], prefix: folderPath)
                )
            }
        return folderNodes + fileNodes
    }
}

// MARK: - File icons

enum WorkspaceFileIcon {
    static func systemName(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "globe"
        case "css", "scss", "sass": return "paintbrush"
        case "js", "jsx", "ts", "tsx", "swift", "py", "rb", "go", "rs",
             "c", "cpp", "h", "hpp", "java", "kt", "php", "sh", "sql":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "xml", "plist": return "curlybraces"
        case "md", "txt": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg", "ico", "webp": return "photo"
        case "csv": return "tablecells"
        default: return "doc"
        }
    }
}
