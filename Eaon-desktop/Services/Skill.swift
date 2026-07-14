import Foundation

/// Where an installed skill came from — purely informational (shown in the
/// library so a user can tell a hand-written one from an imported one), never
/// consulted for behavior.
enum SkillSource: Codable, Equatable {
    /// Shipped with Eaon, seeded once on first launch.
    case starter
    /// Imported from this Mac's own `~/.claude/skills/<name>/SKILL.md` —
    /// `path` is that file's real path, kept for display only.
    case localImport(path: String)
    /// Installed from a GitHub URL — kept so re-installing updates the same
    /// entry instead of creating a duplicate.
    case github(url: String)
    /// Typed or pasted directly into the "Add manually" sheet.
    case manual
}

/// One installed skill: a name (used for `/name` invocation in the
/// composer), a one-line summary, and the instruction body injected into the
/// system prompt when invoked. Mirrors Claude Code's own SKILL.md shape
/// deliberately — same frontmatter fields, same idea of "a name plus a
/// description plus instructions" — since that's the exact convention the
/// user is already familiar with and the one real skills in the wild
/// (`~/.claude/skills/`, GitHub) are already written in.
struct Skill: Identifiable, Codable, Equatable {
    var id = UUID()
    /// Lowercase, hyphenated — what the user types after `/` to invoke this
    /// skill. Derived from the source file's own `name:` frontmatter via
    /// `SkillParser.normalizeName`, never entered separately.
    var name: String
    var summary: String
    var instructions: String
    var source: SkillSource
    /// Disabled skills stay installed (so re-enabling doesn't mean
    /// reinstalling) but are invisible to `/` autocomplete and can't be
    /// invoked — the model never sees a disabled skill's instructions.
    var isEnabled: Bool = true
    var installedAt: Date = Date()
}

/// Parses the SKILL.md convention: a leading frontmatter block delimited by
/// `---` lines containing flat `key: value` pairs, then a markdown body used
/// as-is as the instructions. Deliberately not a general YAML parser — every
/// real skill (Claude Code's own, and the ones this was tested against)
/// keeps `name`/`description` as plain single-line scalars, so this only
/// needs to handle that one shape.
enum SkillParser {
    struct ParsedSkill: Equatable {
        let name: String
        let summary: String
        let instructions: String
    }

    enum ParseError: Error, LocalizedError, Equatable {
        case noFrontmatter
        case missingName
        case missingDescription

        var errorDescription: String? {
            switch self {
            case .noFrontmatter:
                return "This doesn't look like a SKILL.md file — it needs to start with a --- frontmatter block containing name: and description: fields."
            case .missingName:
                return "The frontmatter is missing a name: field."
            case .missingDescription:
                return "The frontmatter is missing a description: field."
            }
        }
    }

    static func parse(_ text: String) throws -> ParsedSkill {
        // `.whitespacesAndNewlines` (not just `.whitespaces`) for every trim
        // below — `.whitespaces` excludes \r, so a CRLF-saved file (plausible
        // for anything fetched from GitHub) would never match a bare "---".
        let lines = text.components(separatedBy: "\n")
        guard let firstLine = lines.first,
              firstLine.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            throw ParseError.noFrontmatter
        }
        guard let closingOffset = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else {
            throw ParseError.noFrontmatter
        }

        var fields: [String: String] = [:]
        for line in lines[1..<closingOffset] {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            fields[key] = value
        }

        guard let rawName = fields["name"], !rawName.isEmpty else { throw ParseError.missingName }
        guard let description = fields["description"], !description.isEmpty else { throw ParseError.missingDescription }

        let bodyLines = lines[(closingOffset + 1)...]
        let instructions = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedSkill(name: normalizeName(rawName), summary: description, instructions: instructions)
    }

    /// Slugifies a frontmatter `name:` into something safe to type after
    /// `/` — lowercase, spaces/underscores to hyphens, anything else that
    /// isn't alphanumeric or a hyphen dropped outright.
    static func normalizeName(_ raw: String) -> String {
        let lowered = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let hyphenated = lowered
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        let filtered = hyphenated.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        return String(String.UnicodeScalarView(filtered))
    }
}

struct LocalSkillCandidate: Identifiable {
    var id: String { path }
    let path: String
    let parsed: SkillParser.ParsedSkill
}

enum SkillInstallError: Error, LocalizedError, Equatable {
    case invalidURL
    case notFound
    case notUTF8

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That doesn't look like a github.com or raw.githubusercontent.com URL."
        case .notFound:
            return "Couldn't find a SKILL.md file there — tried the URL directly and, if it looked like a folder, a SKILL.md inside it."
        case .notUTF8:
            return "That file isn't readable as text."
        }
    }
}

/// Owns every installed skill — storage, enable/disable, GitHub install, and
/// importing from this Mac's own local Claude Code skills folder. One store,
/// UserDefaults-backed JSON, matching every other list this app persists
/// this way (conversations, projects, custom providers).
@MainActor
@Observable
final class SkillStore {
    static let shared = SkillStore()

    private let storageKey = "eaon_skills"
    private(set) var skills: [Skill] = []

    private init() {
        load()
        if skills.isEmpty {
            seedStarterSkills()
        }
    }

    var sortedSkills: [Skill] {
        skills.sorted { $0.installedAt < $1.installedAt }
    }

    /// What `/` autocomplete offers and what a slash invocation can match —
    /// a disabled skill is installed but inert.
    var enabledSkills: [Skill] {
        skills.filter(\.isEnabled)
    }

    /// Case-insensitive lookup by the hyphenated `/name` form, enabled skills
    /// only.
    func skill(named name: String) -> Skill? {
        let normalized = SkillParser.normalizeName(name)
        guard !normalized.isEmpty else { return nil }
        return enabledSkills.first { $0.name == normalized }
    }

    func toggle(_ id: UUID) {
        guard let index = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[index].isEnabled.toggle()
        persist()
    }

    func remove(_ id: UUID) {
        skills.removeAll { $0.id == id }
        persist()
    }

    /// A skill by this name already existing is refused rather than
    /// silently duplicated — `/name` invocation has to resolve to exactly
    /// one skill, and two entries answering to the same command would be
    /// confusing regardless.
    @discardableResult
    func addManual(name: String, summary: String, instructions: String) throws -> Skill {
        let normalized = SkillParser.normalizeName(name)
        guard !normalized.isEmpty else { throw SkillParser.ParseError.missingName }
        guard !skills.contains(where: { $0.name == normalized }) else {
            throw SkillStoreError.duplicateName(normalized)
        }
        let skill = Skill(name: normalized, summary: summary, instructions: instructions, source: .manual)
        skills.append(skill)
        persist()
        return skill
    }

    /// Installs (or re-installs, updating in place) a skill from a GitHub
    /// URL. Accepts a `raw.githubusercontent.com` link, a `blob` file link,
    /// a `tree` folder link, or a bare repo link — see
    /// `Self.candidateRawURLs` for exactly what's tried for each shape.
    @discardableResult
    func addFromGitHub(url rawURL: String) async throws -> Skill {
        let candidates = Self.candidateRawURLs(for: rawURL)
        guard !candidates.isEmpty else { throw SkillInstallError.invalidURL }

        var lastError: Error = SkillInstallError.notFound
        for candidateURL in candidates {
            do {
                let (data, response) = try await URLSession.shared.data(from: candidateURL)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    lastError = SkillInstallError.notFound
                    continue
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    lastError = SkillInstallError.notUTF8
                    continue
                }
                let parsed = try SkillParser.parse(text)
                return upsert(parsed: parsed, source: .github(url: rawURL))
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Every `SKILL.md` under `~/.claude/skills/<folder>/` not already
    /// present in the library (matched by normalized name) — feeds the
    /// "Import from Claude Code" picker. Silently skips anything that
    /// doesn't parse rather than surfacing an error for a folder the user
    /// didn't ask about directly.
    func localClaudeSkillCandidates() -> [LocalSkillCandidate] {
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/skills")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        let existingNames = Set(skills.map(\.name))
        var candidates: [LocalSkillCandidate] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let skillFile = entry.appendingPathComponent("SKILL.md")
            guard let data = try? Data(contentsOf: skillFile), let text = String(data: data, encoding: .utf8) else { continue }
            guard let parsed = try? SkillParser.parse(text), !existingNames.contains(parsed.name) else { continue }
            candidates.append(LocalSkillCandidate(path: skillFile.path, parsed: parsed))
        }
        return candidates
    }

    func importLocal(_ candidate: LocalSkillCandidate) {
        guard !skills.contains(where: { $0.name == candidate.parsed.name }) else { return }
        skills.append(Skill(
            name: candidate.parsed.name, summary: candidate.parsed.summary,
            instructions: candidate.parsed.instructions, source: .localImport(path: candidate.path)
        ))
        persist()
    }

    private func upsert(parsed: SkillParser.ParsedSkill, source: SkillSource) -> Skill {
        if let index = skills.firstIndex(where: { $0.name == parsed.name }) {
            skills[index].summary = parsed.summary
            skills[index].instructions = parsed.instructions
            skills[index].source = source
            persist()
            return skills[index]
        }
        let skill = Skill(name: parsed.name, summary: parsed.summary, instructions: parsed.instructions, source: source)
        skills.append(skill)
        persist()
        return skill
    }

    /// Turns a GitHub URL of almost any shape into one or more raw-content
    /// URLs worth trying, most-likely-correct first:
    /// - `raw.githubusercontent.com/...` is used exactly as given.
    /// - A `blob` file URL (`github.com/org/repo/blob/branch/path`)
    ///   converts directly to its raw equivalent.
    /// - A `tree` folder URL tries `SKILL.md` inside that folder first,
    ///   then the path itself (in case it was actually a file GitHub
    ///   rendered under `/tree/`, which happens with some share links).
    /// - A bare repo URL (`github.com/org/repo`) tries `SKILL.md` at the
    ///   root on the two common default-branch names — asking GitHub's API
    ///   which branch is actually default would be a second round-trip a
    ///   direct file link avoids entirely.
    /// `nonisolated` deliberately — this touches no instance state at all
    /// (pure string→URL logic), so it shouldn't force a MainActor hop just
    /// because it happens to live inside this `@MainActor` class, whose
    /// isolation every member otherwise inherits by default.
    nonisolated static func candidateRawURLs(for rawInput: String) -> [URL] {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let host = components.host else { return [] }

        if host == "raw.githubusercontent.com" {
            return URL(string: trimmed).map { [$0] } ?? []
        }
        guard host == "github.com" else { return [] }

        let segments = components.path.split(separator: "/").map(String.init)
        guard segments.count >= 2 else { return [] }
        let org = segments[0]
        let repo = segments[1]

        func rawURL(branch: String, filePath: String) -> URL? {
            URL(string: "https://raw.githubusercontent.com/\(org)/\(repo)/\(branch)/\(filePath)")
        }

        var results: [URL] = []
        if segments.count >= 4, segments[2] == "blob" || segments[2] == "tree" {
            let branch = segments[3]
            let restPath = segments.dropFirst(4).joined(separator: "/")
            if segments[2] == "blob" {
                if let url = rawURL(branch: branch, filePath: restPath) { results.append(url) }
            } else {
                if let url = rawURL(branch: branch, filePath: restPath.isEmpty ? "SKILL.md" : restPath + "/SKILL.md") {
                    results.append(url)
                }
                if !restPath.isEmpty, let url = rawURL(branch: branch, filePath: restPath) {
                    results.append(url)
                }
            }
        } else if segments.count == 2 {
            for branch in ["main", "master"] {
                if let url = rawURL(branch: branch, filePath: "SKILL.md") { results.append(url) }
            }
        }
        return results
    }

    private func seedStarterSkills() {
        for starter in StarterSkills.all {
            guard let parsed = try? SkillParser.parse(starter) else { continue }
            skills.append(Skill(name: parsed.name, summary: parsed.summary, instructions: parsed.instructions, source: .starter))
        }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Skill].self, from: data) else { return }
        skills = decoded
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(skills) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }
}

enum SkillStoreError: Error, LocalizedError, Equatable {
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .duplicateName(let name):
            return "A skill named \"\(name)\" is already installed — remove or rename it first."
        }
    }
}
