// Agent mode's coding tools — the cross-platform Rust port of the macOS
// app's `DesktopControlService` (Eaon-desktop/Services/DesktopControl.swift).
// Same tool set, same safety model, same result shape, so the Windows/Linux
// Agent behaves identically to the Mac one: create a project folder, write
// real source files, run them, read output, search an existing codebase, and
// iterate.
//
// Everything routes through one `run_agent_tool` command (mirrors the Mac
// `execute(tool:arguments:)` dispatcher) so the frontend's invoke surface is
// tiny. All file mutation is confined to the user's home folder or the OS
// temp dir — the cross-platform equivalent of the Mac guard (home / /Volumes
// / /tmp). System locations are refused outright, and privilege escalation
// (`sudo`, `runas`) is blocked in the shell.

use serde::Serialize;
use serde_json::Value;
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

/// One tool result — `ok` distinguishes success from failure so the frontend
/// can render "### tool\nOK:" vs "ERROR:" exactly like the Mac agent loop.
#[derive(Serialize, Clone)]
pub struct ToolOutcome {
    pub ok: bool,
    pub text: String,
}

impl ToolOutcome {
    fn ok(text: impl Into<String>) -> Self {
        ToolOutcome { ok: true, text: text.into() }
    }
    fn err(text: impl Into<String>) -> Self {
        ToolOutcome { ok: false, text: text.into() }
    }
}

const SHELL_TIMEOUT_SECS: u64 = 60;
const SHELL_OUTPUT_CAP: usize = 12_000;
const READ_CAP_CHARS: usize = 12_000;
const SEARCH_MAX_HITS: usize = 120;
const SEARCH_MAX_FILES: usize = 20_000;
const FIND_MAX_VISITED: usize = 80_000;

fn arg_str<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args.get(key).and_then(|v| v.as_str())
}

// MARK: - Path safety

fn home_dir() -> PathBuf {
    // No external `dirs` crate — read the platform's own home variable.
    if cfg!(windows) {
        std::env::var_os("USERPROFILE")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("C:\\Users\\Default"))
    } else {
        std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
    }
}

/// Lexically normalize (resolve `.`/`..`, expand a leading `~`, make absolute
/// against home) WITHOUT touching the filesystem — so it works for a
/// not-yet-created file. When the path already exists we additionally
/// `canonicalize` to collapse symlinks, closing the "symlink under home
/// points outside" escape the Mac version guards with `resolvingSymlinksInPath`.
fn normalize(raw: &str) -> PathBuf {
    let raw = raw.trim();
    let expanded: PathBuf = if raw == "~" {
        home_dir()
    } else if let Some(rest) = raw.strip_prefix("~/").or_else(|| raw.strip_prefix("~\\")) {
        home_dir().join(rest)
    } else {
        PathBuf::from(raw)
    };

    let absolute = if expanded.is_absolute() { expanded } else { home_dir().join(expanded) };

    let mut out = PathBuf::new();
    for comp in absolute.components() {
        match comp {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }

    // Resolve symlinks so the guard can't be fooled — and so a path matches
    // the canonicalized allow-roots. When the full path exists, canonicalize
    // it directly. When it doesn't (a not-yet-created file), canonicalize the
    // deepest EXISTING ancestor and re-append the remaining components — this
    // is what makes a new file under a symlinked temp dir (macOS `/var` →
    // `/private/var`) resolve to the same root as `allowed_write_bases`.
    if let Ok(canon) = std::fs::canonicalize(&out) {
        return canon;
    }
    let mut ancestor = out.clone();
    let mut tail: Vec<std::ffi::OsString> = Vec::new();
    while !ancestor.exists() {
        if let Some(name) = ancestor.file_name() {
            tail.push(name.to_os_string());
        }
        if !ancestor.pop() {
            break;
        }
    }
    let mut base = std::fs::canonicalize(&ancestor).unwrap_or(ancestor);
    for name in tail.iter().rev() {
        base.push(name);
    }
    base
}

/// System locations a write/move must never touch. Most would be refused by
/// the OS anyway, but a clear "that's a protected system path" beats a
/// confusing permission error — and it stops the model shuffling things
/// around inside them.
fn is_protected(path: &Path) -> bool {
    let p = path.to_string_lossy();
    if cfg!(windows) {
        let lower = p.to_lowercase();
        lower.starts_with("c:\\windows")
            || lower.starts_with("c:\\program files")
            || lower.starts_with("c:\\programdata")
    } else {
        const ROOTS: &[&str] = &[
            "/System", "/usr", "/bin", "/sbin", "/private/var", "/private/etc",
            "/Library", "/opt", "/cores",
        ];
        ROOTS.iter().any(|r| p == *r || p.starts_with(&format!("{r}/")))
    }
}

fn is_within(base: &Path, path: &Path) -> bool {
    path == base || path.starts_with(base)
}

/// The two safe write roots: the user's home folder and the OS temp dir. Both
/// are canonicalized so a symlinked temp (macOS `TMPDIR` resolves under
/// `/private/var/...`) still matches a canonicalized target path.
fn allowed_write_bases() -> Vec<PathBuf> {
    let mut bases = vec![normalize(&home_dir().to_string_lossy())];
    let temp = std::env::temp_dir();
    bases.push(std::fs::canonicalize(&temp).unwrap_or(temp));
    bases
}

/// True for a path safe to modify — under the user's home folder or the OS
/// temp dir. The cross-platform analogue of the Mac `isModifiablePath` (home
/// / /Volumes / /tmp). Default-deny: anything outside those two roots (which
/// includes every protected system location) is refused.
fn is_modifiable(path: &Path) -> bool {
    allowed_write_bases().iter().any(|b| is_within(b, path))
}

fn guard_modifiable(path: &Path, action: &str) -> Option<ToolOutcome> {
    if is_modifiable(path) {
        None
    } else {
        Some(ToolOutcome::err(format!(
            "Refused: {action} is only allowed on paths under your home folder or the temp folder — not \"{}\", which is a system or out-of-scope location.",
            path.display()
        )))
    }
}

/// A search/find root must exist, be a directory, and not be a drive root or
/// system location — a recursive walk from the top of a drive would be
/// catastrophic even though it only reads.
fn resolve_search_root(raw: &str) -> Result<PathBuf, ToolOutcome> {
    let path = normalize(raw);
    if !path.exists() {
        return Err(ToolOutcome::err(format!("No such directory: {}", path.display())));
    }
    if !path.is_dir() {
        return Err(ToolOutcome::err(format!(
            "That's a file, not a folder: {} — give the directory to search under.",
            path.display()
        )));
    }
    // Home and temp are always searchable — checked BEFORE the protected
    // check, since the OS temp dir lives under a protected root on macOS.
    if allowed_write_bases().iter().any(|b| is_within(b, &path)) {
        return Ok(path);
    }
    // Refuse a filesystem/drive root (e.g. "/" or "C:\").
    if path.parent().is_none() {
        return Err(ToolOutcome::err(
            "Refused: searching from a drive root would scan the whole disk. Point at a project folder.".to_string(),
        ));
    }
    if is_protected(&path) {
        return Err(ToolOutcome::err(format!(
            "Refused: {} is a system location. Search within a project under your home folder instead.",
            path.display()
        )));
    }
    // Any other readable user directory is fine for a read-only search.
    Ok(path)
}

// MARK: - Noise skipping / helpers shared by search + find

fn is_noise_dir(name: &str) -> bool {
    const NOISE: &[&str] = &[
        ".git", ".hg", ".svn", "node_modules", ".build", "build", "dist",
        ".next", ".nuxt", "out", ".venv", "venv", "env", "__pycache__",
        ".mypy_cache", ".pytest_cache", "Pods", "Carthage", "DerivedData",
        ".gradle", "target", ".idea", ".cache", "vendor", ".terraform",
    ];
    NOISE.contains(&name)
}

fn looks_binary(bytes: &[u8]) -> bool {
    bytes.iter().take(8_000).any(|&b| b == 0)
}

/// Glob (`*`, `?`) → anchored, filename-only regex string.
fn glob_to_regex(glob: &str) -> String {
    let mut out = String::from("^");
    for ch in glob.chars() {
        match ch {
            '*' => out.push_str("[^/\\\\]*"),
            '?' => out.push_str("[^/\\\\]"),
            '.' | '(' | ')' | '+' | '|' | '^' | '$' | '{' | '}' | '[' | ']' | '\\' => {
                out.push('\\');
                out.push(ch);
            }
            other => out.push(other),
        }
    }
    out.push('$');
    out
}

fn relative_to(full: &Path, root: &Path) -> String {
    full.strip_prefix(root)
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .unwrap_or_else(|_| full.to_string_lossy().to_string())
}

/// Recursive directory walk that skips noise dirs, calling `visit` for each
/// file. `visit` returns false to stop the whole walk early. Returns whether
/// it stopped early (truncated).
fn walk_files<F: FnMut(&Path) -> bool>(root: &Path, budget: &mut usize, visit: &mut F) -> bool {
    let entries = match std::fs::read_dir(root) {
        Ok(e) => e,
        Err(_) => return false,
    };
    for entry in entries.flatten() {
        if *budget == 0 {
            return true;
        }
        *budget -= 1;
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
        if is_dir {
            if is_noise_dir(&name) {
                continue;
            }
            if walk_files(&path, budget, visit) {
                return true;
            }
        } else if !visit(&path) {
            return true;
        }
    }
    false
}

// MARK: - File operations

fn list_directory(args: &Value) -> ToolOutcome {
    let raw = match arg_str(args, "path") {
        Some(p) => p,
        None => return ToolOutcome::err("missing \"path\""),
    };
    let path = normalize(raw);
    if !path.exists() {
        return ToolOutcome::err(format!("No such directory: {}", path.display()));
    }
    if !path.is_dir() {
        return ToolOutcome::err(format!("Not a directory (it's a file): {}", path.display()));
    }
    let mut names: Vec<String> = match std::fs::read_dir(&path) {
        Ok(rd) => rd
            .flatten()
            .map(|e| {
                let n = e.file_name().to_string_lossy().to_string();
                if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    format!("{n}/")
                } else {
                    n
                }
            })
            .collect(),
        Err(e) => return ToolOutcome::err(format!("Couldn't list {}: {e}", path.display())),
    };
    if names.is_empty() {
        return ToolOutcome::ok(format!("{} is empty.", path.display()));
    }
    names.sort();
    let total = names.len();
    let shown: Vec<String> = names.into_iter().take(500).collect();
    let more = if total > 500 { format!("\n…and {} more", total - 500) } else { String::new() };
    ToolOutcome::ok(format!("{total} item(s) in {}:\n{}{more}", path.display(), shown.join("\n")))
}

fn create_folder(args: &Value) -> ToolOutcome {
    let raw = match arg_str(args, "path") {
        Some(p) => p,
        None => return ToolOutcome::err("missing \"path\""),
    };
    let path = normalize(raw);
    if let Some(denied) = guard_modifiable(&path, "creating a folder") {
        return denied;
    }
    if path.is_dir() {
        return ToolOutcome::ok(format!("Already exists: {} — the folder is there, use it.", path.display()));
    }
    if path.is_file() {
        return ToolOutcome::err(format!("A file (not a folder) already exists at {}.", path.display()));
    }
    match std::fs::create_dir_all(&path) {
        Ok(_) => ToolOutcome::ok(format!("Created folder {}", path.display())),
        Err(e) => ToolOutcome::err(format!("Couldn't create it: {e}")),
    }
}

fn write_file(args: &Value) -> ToolOutcome {
    let raw = match arg_str(args, "path") {
        Some(p) => p,
        None => return ToolOutcome::err("missing \"path\""),
    };
    let content = match arg_str(args, "content") {
        Some(c) => c,
        None => return ToolOutcome::err("missing \"content\""),
    };
    let path = normalize(raw);
    if let Some(denied) = guard_modifiable(&path, "writing a file") {
        return denied;
    }
    if path.is_dir() {
        return ToolOutcome::err(format!("That path is a folder, not a file: {}", path.display()));
    }
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                return ToolOutcome::err(format!("Couldn't create parent folder: {e}"));
            }
        }
    }
    match std::fs::write(&path, content) {
        Ok(_) => {
            let lines = if content.is_empty() { 0 } else { content.split('\n').count() };
            ToolOutcome::ok(format!("Wrote {} ({lines} line(s), {} byte(s)).", path.display(), content.len()))
        }
        Err(e) => ToolOutcome::err(format!("Couldn't write it: {e}")),
    }
}

fn read_file(args: &Value) -> ToolOutcome {
    let raw = match arg_str(args, "path") {
        Some(p) => p,
        None => return ToolOutcome::err("missing \"path\""),
    };
    let path = normalize(raw);
    if !path.exists() {
        return ToolOutcome::err(format!("No such file: {}", path.display()));
    }
    if path.is_dir() {
        return ToolOutcome::err(format!("That's a folder, not a file: {} — use list_directory.", path.display()));
    }
    let bytes = match std::fs::read(&path) {
        Ok(b) => b,
        Err(e) => return ToolOutcome::err(format!("Couldn't read {}: {e}", path.display())),
    };
    if bytes.len() > 5_000_000 {
        return ToolOutcome::err(format!("Too large to read whole ({} bytes).", bytes.len()));
    }
    let content = match String::from_utf8(bytes) {
        Ok(s) => s,
        Err(_) => return ToolOutcome::err(format!("Not a UTF-8 text file: {}", path.display())),
    };
    let lines = if content.is_empty() { 0 } else { content.split('\n').count() };
    let capped: String = if content.chars().count() > READ_CAP_CHARS {
        let head: String = content.chars().take(READ_CAP_CHARS).collect();
        format!("{head}\n…(truncated at 12k characters)")
    } else {
        content
    };
    ToolOutcome::ok(format!("{} ({lines} line(s)):\n{capped}", path.display()))
}

fn edit_file(args: &Value) -> ToolOutcome {
    let raw = match arg_str(args, "path") {
        Some(p) => p,
        None => return ToolOutcome::err("missing \"path\""),
    };
    let search = match arg_str(args, "search") {
        Some(s) if !s.is_empty() => s,
        _ => return ToolOutcome::err("missing a non-empty \"search\" — the exact existing text to find."),
    };
    let replace = match arg_str(args, "replace") {
        Some(r) => r,
        None => return ToolOutcome::err("missing \"replace\" — use \"\" to delete the matched text."),
    };
    let path = normalize(raw);
    if let Some(denied) = guard_modifiable(&path, "editing a file") {
        return denied;
    }
    if !path.exists() {
        return ToolOutcome::err(format!("No such file: {} — to create a new file, use write_file.", path.display()));
    }
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return ToolOutcome::err(format!("Couldn't read {} as UTF-8 text.", path.display())),
    };
    // Exactly-once semantics, matching the Mac WorkspaceParser.applyEdit.
    let count = content.matches(search).count();
    if count == 0 {
        return ToolOutcome::err("Edit not applied — the search text wasn't found. Use read_file to see the current contents, then retry with an exact match.".to_string());
    }
    if count > 1 {
        return ToolOutcome::err(format!("Edit not applied — the search text appears {count} times; it must occur exactly once. Include more surrounding lines to make it unique."));
    }
    let new_content = content.replacen(search, replace, 1);
    match std::fs::write(&path, &new_content) {
        Ok(_) => {
            let lines = if new_content.is_empty() { 0 } else { new_content.split('\n').count() };
            ToolOutcome::ok(format!("Edited {} — replaced 1 occurrence. The file is now {lines} line(s).", path.display()))
        }
        Err(e) => ToolOutcome::err(format!("Couldn't write the edit: {e}")),
    }
}

fn move_item(args: &Value) -> ToolOutcome {
    let from_raw = match arg_str(args, "from") {
        Some(p) => p,
        None => return ToolOutcome::err("missing \"from\""),
    };
    let to_raw = match arg_str(args, "to") {
        Some(p) => p,
        None => return ToolOutcome::err("missing \"to\""),
    };
    let from = normalize(from_raw);
    let to = normalize(to_raw);
    if let Some(d) = guard_modifiable(&from, "moving an item") {
        return d;
    }
    if let Some(d) = guard_modifiable(&to, "moving an item") {
        return d;
    }
    if !from.exists() {
        return ToolOutcome::err(format!("Nothing to move — no such path: {}", from.display()));
    }
    if to.exists() {
        return ToolOutcome::err(format!("Something already exists at {} — refused rather than overwrite it.", to.display()));
    }
    if let Some(parent) = to.parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            let _ = std::fs::create_dir_all(parent);
        }
    }
    match std::fs::rename(&from, &to) {
        Ok(_) => ToolOutcome::ok(format!("Moved {} → {}", from.display(), to.display())),
        Err(e) => ToolOutcome::err(format!("Couldn't move it: {e}")),
    }
}

// MARK: - Shell

fn mentions_escalation(command: &str) -> bool {
    let lower = format!(" {} ", command.to_lowercase());
    lower.contains(" sudo ") || lower.contains(" runas ") || lower.contains("|sudo ") || lower.contains("| sudo ")
}

fn run_shell(args: &Value) -> ToolOutcome {
    let command = match arg_str(args, "command").map(|c| c.trim()) {
        Some(c) if !c.is_empty() => c.to_string(),
        _ => return ToolOutcome::err("missing a non-empty \"command\""),
    };
    if mentions_escalation(&command) {
        return ToolOutcome::err("Refused: this runs commands as you, never as an administrator. Drop the sudo/runas.".to_string());
    }

    let mut working_dir = home_dir();
    if let Some(wd_raw) = arg_str(args, "working_directory") {
        let wd = normalize(wd_raw);
        if !wd.is_dir() {
            return ToolOutcome::err(format!("working_directory isn't a directory: {}", wd.display()));
        }
        working_dir = wd;
    }

    let mut cmd = if cfg!(windows) {
        let mut c = Command::new("cmd");
        c.args(["/C", &command]);
        c
    } else {
        let mut c = Command::new("sh");
        c.args(["-c", &command]);
        c
    };
    cmd.current_dir(&working_dir);

    let mut child = match cmd
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .stdin(std::process::Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return ToolOutcome::err(format!("Couldn't run it: {e}")),
    };

    // Poll for completion with a hard timeout, then kill — std has no
    // built-in wait-with-timeout and we avoid adding a crate for it.
    let start = Instant::now();
    let timed_out = loop {
        match child.try_wait() {
            Ok(Some(_)) => break false,
            Ok(None) => {
                if start.elapsed() >= Duration::from_secs(SHELL_TIMEOUT_SECS) {
                    let _ = child.kill();
                    let _ = child.wait();
                    break true;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => return ToolOutcome::err(format!("Couldn't wait on the command: {e}")),
        }
    };

    let output = match child.wait_with_output() {
        Ok(o) => o,
        Err(e) => return ToolOutcome::err(format!("Couldn't read the command's output: {e}")),
    };
    let mut combined = String::new();
    combined.push_str(&String::from_utf8_lossy(&output.stdout));
    combined.push_str(&String::from_utf8_lossy(&output.stderr));
    let capped: String = if combined.chars().count() > SHELL_OUTPUT_CAP {
        let head: String = combined.chars().take(SHELL_OUTPUT_CAP).collect();
        format!("{head}\n…(output truncated at 12k characters)")
    } else {
        combined
    };
    let code = output.status.code();
    if timed_out {
        return ToolOutcome::err(format!("Command killed after {SHELL_TIMEOUT_SECS}s (still running).\n{capped}"));
    }
    let ok = code == Some(0);
    let header = match code {
        Some(0) => "exit code: 0".to_string(),
        Some(n) => format!("exit code: {n}"),
        None => "exited by signal".to_string(),
    };
    let body = if capped.trim().is_empty() { "(no output)".to_string() } else { capped };
    ToolOutcome { ok, text: format!("{header}\n{body}") }
}

// MARK: - Code search / file finding

fn find_files(args: &Value) -> ToolOutcome {
    let raw_path = match arg_str(args, "path") {
        Some(p) => p,
        None => return ToolOutcome::err("missing \"path\" — the folder to search under."),
    };
    let pattern = match arg_str(args, "name_pattern").map(|p| p.trim()) {
        Some(p) if !p.is_empty() => p.to_string(),
        _ => return ToolOutcome::err("missing \"name_pattern\" — a glob like \"*.rs\" or part of a filename."),
    };
    let root = match resolve_search_root(raw_path) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let max_results = args.get("max_results").and_then(|v| v.as_u64()).unwrap_or(200).clamp(1, 1000) as usize;

    let is_glob = pattern.contains('*') || pattern.contains('?');
    let glob_re = if is_glob {
        regex::RegexBuilder::new(&glob_to_regex(&pattern)).case_insensitive(true).build().ok()
    } else {
        None
    };
    let needle = pattern.to_lowercase();

    let mut matches: Vec<String> = Vec::new();
    let mut budget = FIND_MAX_VISITED;
    let mut truncated = false;
    walk_files(&root, &mut budget, &mut |file| {
        let name = file.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        let hit = match &glob_re {
            Some(re) => re.is_match(&name),
            None => name.to_lowercase().contains(&needle),
        };
        if hit {
            matches.push(relative_to(file, &root));
            if matches.len() >= max_results {
                truncated = true;
                return false;
            }
        }
        true
    });
    if matches.is_empty() {
        return ToolOutcome::ok(format!("No files matching \"{pattern}\" under {}.", root.display()));
    }
    matches.sort();
    let note = if truncated { "\n…(more matches exist — narrow name_pattern or raise max_results)" } else { "" };
    ToolOutcome::ok(format!(
        "{} file(s) matching \"{pattern}\" under {}:\n{}{note}",
        matches.len(),
        root.display(),
        matches.join("\n")
    ))
}

fn search_code(args: &Value) -> ToolOutcome {
    let raw_pattern = match arg_str(args, "pattern") {
        Some(p) if !p.is_empty() => p,
        _ => return ToolOutcome::err("missing a non-empty \"pattern\"."),
    };
    let raw_path = match arg_str(args, "path") {
        Some(p) => p,
        None => return ToolOutcome::err("missing \"path\" — the project folder to search."),
    };
    let root = match resolve_search_root(raw_path) {
        Ok(r) => r,
        Err(e) => return e,
    };
    let case_sensitive = args.get("case_sensitive").and_then(|v| v.as_bool()).unwrap_or(false);

    // Invalid regex falls back to a literal substring search — a model often
    // types plain text it means literally.
    let regex = regex::RegexBuilder::new(raw_pattern)
        .case_insensitive(!case_sensitive)
        .build()
        .or_else(|_| {
            regex::RegexBuilder::new(&regex::escape(raw_pattern))
                .case_insensitive(!case_sensitive)
                .build()
        });
    let regex = match regex {
        Ok(r) => r,
        Err(_) => return ToolOutcome::err(format!("Couldn't build a search out of \"{raw_pattern}\".")),
    };

    let file_glob = arg_str(args, "file_glob").map(|g| g.trim()).filter(|g| !g.is_empty());
    let glob_re = file_glob.and_then(|g| {
        regex::RegexBuilder::new(&glob_to_regex(g)).case_insensitive(true).build().ok()
    });

    let mut hits: Vec<String> = Vec::new();
    let mut files_with_hits = std::collections::HashSet::new();
    let mut files_scanned = 0usize;
    let mut budget = SEARCH_MAX_FILES * 4;
    let mut truncated = false;

    walk_files(&root, &mut budget, &mut |file| {
        let name = file.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        if let Some(re) = &glob_re {
            if !re.is_match(&name) {
                return true;
            }
        }
        if let Ok(meta) = file.metadata() {
            if meta.len() > 2_000_000 {
                return true;
            }
        }
        files_scanned += 1;
        if files_scanned > SEARCH_MAX_FILES {
            truncated = true;
            return false;
        }
        let bytes = match std::fs::read(file) {
            Ok(b) => b,
            Err(_) => return true,
        };
        if looks_binary(&bytes) {
            return true;
        }
        let content = match String::from_utf8(bytes) {
            Ok(s) => s,
            Err(_) => return true,
        };
        let rel = relative_to(file, &root);
        for (idx, line) in content.split('\n').enumerate() {
            if regex.is_match(line) {
                let trimmed = line.trim();
                let shown: String = if trimmed.chars().count() > 200 {
                    format!("{}…", trimmed.chars().take(200).collect::<String>())
                } else {
                    trimmed.to_string()
                };
                hits.push(format!("{rel}:{}: {shown}", idx + 1));
                files_with_hits.insert(rel.clone());
                if hits.len() >= SEARCH_MAX_HITS {
                    truncated = true;
                    return false;
                }
            }
        }
        true
    });

    if hits.is_empty() {
        return ToolOutcome::ok(format!("No matches for /{raw_pattern}/ under {}.", root.display()));
    }
    let note = if truncated { "\n…(more matches — narrow the pattern or add a file_glob)" } else { "" };
    ToolOutcome::ok(format!(
        "{} match(es) in {} file(s) for /{raw_pattern}/ under {}:\n{}{note}",
        hits.len(),
        files_with_hits.len(),
        root.display(),
        hits.join("\n")
    ))
}

// MARK: - Dispatcher (mirrors the Mac execute(tool:arguments:))

/// The single entry point the frontend agent loop calls. `run_shell`,
/// `search_code`, and `find_files` can be slow, so the whole thing runs on a
/// blocking thread to keep the UI responsive.
#[tauri::command]
pub async fn run_agent_tool(name: String, args: Value) -> ToolOutcome {
    tauri::async_runtime::spawn_blocking(move || match name.as_str() {
        "list_directory" => list_directory(&args),
        "create_folder" => create_folder(&args),
        "write_file" => write_file(&args),
        "read_file" => read_file(&args),
        "edit_file" => edit_file(&args),
        "move_item" => move_item(&args),
        "run_shell" => run_shell(&args),
        "search_code" => search_code(&args),
        "find_files" => find_files(&args),
        "trash_item" => trash_item(&args),
        "open_app" => open_app(&args),
        "quit_app" => quit_app(&args),
        "open_url" => open_url(&args),
        "open_path" => open_path(&args),
        other => ToolOutcome::err(format!("no such tool: {other}")),
    })
    .await
    .unwrap_or_else(|e| ToolOutcome::err(format!("tool crashed: {e}")))
}

// ---------------------------------------------------------------------------
// Device tools — the portable subset of the Mac app's wider (formerly "Eaon
// Claw") catalog: Trash, open/quit apps, open URLs/paths. `run_applescript`
// has no cross-platform analogue and is deliberately absent.
// ---------------------------------------------------------------------------

/// Move a file/folder to the OS trash (Recycle Bin / Trash / gio trash) —
/// recoverable, never a permanent delete, same guard as every write.
fn trash_item(args: &Value) -> ToolOutcome {
    let Some(raw) = arg_str(args, "path") else {
        return ToolOutcome::err("trash_item needs a \"path\".");
    };
    let path = normalize(raw);
    if let Some(refusal) = guard_modifiable(&path, "moving to trash") {
        return refusal;
    }
    if !path.exists() {
        return ToolOutcome::err(format!("No such file or folder: {}", path.display()));
    }
    match trash::delete(&path) {
        Ok(()) => ToolOutcome::ok(format!("Moved to trash: {}", path.display())),
        Err(e) => ToolOutcome::err(format!("Couldn't move to trash: {e}")),
    }
}

/// A sanity gate for app names fed to shell-adjacent launchers — letters,
/// digits, spaces, and a few name chars only, so a "name" can never smuggle
/// shell metacharacters or path traversal.
fn valid_app_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 80
        && name
            .chars()
            .all(|c| c.is_alphanumeric() || matches!(c, ' ' | '-' | '_' | '.' | '+'))
}

/// Open (launch or focus) an application by name, per platform.
fn open_app(args: &Value) -> ToolOutcome {
    let Some(name) = arg_str(args, "name").map(str::trim).filter(|n| !n.is_empty()) else {
        return ToolOutcome::err("open_app needs a \"name\".");
    };
    if !valid_app_name(name) {
        return ToolOutcome::err("open_app: that doesn't look like an application name.");
    }
    let result = if cfg!(target_os = "macos") {
        Command::new("open").arg("-a").arg(name).status()
    } else if cfg!(target_os = "windows") {
        // `start` resolves App Paths/PATH the way a user's Run box would.
        Command::new("cmd").args(["/C", "start", "", name]).status()
    } else {
        // Linux: try the binary name directly (most launchable apps are on
        // PATH); gtk-launch would need the .desktop id, which models rarely
        // know.
        Command::new(name).spawn().map(|_| std::process::ExitStatus::default())
    };
    match result {
        Ok(status) if status.success() => ToolOutcome::ok(format!("Opened {name}.")),
        Ok(_) => ToolOutcome::err(format!("Couldn't open \"{name}\" — is it installed?")),
        Err(e) => ToolOutcome::err(format!("Couldn't open \"{name}\": {e}")),
    }
}

/// Ask an application to quit, per platform — graceful where the OS allows.
fn quit_app(args: &Value) -> ToolOutcome {
    let Some(name) = arg_str(args, "name").map(str::trim).filter(|n| !n.is_empty()) else {
        return ToolOutcome::err("quit_app needs a \"name\".");
    };
    if !valid_app_name(name) {
        return ToolOutcome::err("quit_app: that doesn't look like an application name.");
    }
    let result = if cfg!(target_os = "macos") {
        Command::new("osascript")
            .args(["-e", &format!("tell application \"{name}\" to quit")])
            .status()
    } else if cfg!(target_os = "windows") {
        let image = if name.to_lowercase().ends_with(".exe") {
            name.to_string()
        } else {
            format!("{name}.exe")
        };
        // No /F — a graceful close request, not a kill.
        Command::new("taskkill").args(["/IM", &image]).status()
    } else {
        // SIGTERM by exact process name — the polite Linux ask.
        Command::new("pkill").args(["-x", name]).status()
    };
    match result {
        Ok(status) if status.success() => ToolOutcome::ok(format!("Asked {name} to quit.")),
        Ok(_) => ToolOutcome::err(format!("Couldn't quit \"{name}\" — is it running?")),
        Err(e) => ToolOutcome::err(format!("Couldn't quit \"{name}\": {e}")),
    }
}

/// Open a URL in the default browser. http/https only — no file:, no custom
/// schemes a model could abuse to launch arbitrary handlers.
fn open_url(args: &Value) -> ToolOutcome {
    let Some(url) = arg_str(args, "url").map(str::trim).filter(|u| !u.is_empty()) else {
        return ToolOutcome::err("open_url needs a \"url\".");
    };
    let lower = url.to_lowercase();
    if !lower.starts_with("http://") && !lower.starts_with("https://") {
        return ToolOutcome::err("open_url only opens http(s) URLs.");
    }
    match tauri_plugin_opener::open_url(url, None::<&str>) {
        Ok(()) => ToolOutcome::ok(format!("Opened {url} in the browser.")),
        Err(e) => ToolOutcome::err(format!("Couldn't open the URL: {e}")),
    }
}

/// Open a file/folder with its default app (Explorer/Files/Finder for
/// folders). Read-side: allowed anywhere that exists except protected
/// system roots.
fn open_path(args: &Value) -> ToolOutcome {
    let Some(raw) = arg_str(args, "path") else {
        return ToolOutcome::err("open_path needs a \"path\".");
    };
    let path = normalize(raw);
    if !path.exists() {
        return ToolOutcome::err(format!("No such file or folder: {}", path.display()));
    }
    if is_protected(&path) {
        return ToolOutcome::err("Refused: that's a system location.");
    }
    match tauri_plugin_opener::open_path(path.to_string_lossy().into_owned(), None::<&str>) {
        Ok(()) => ToolOutcome::ok(format!("Opened {}.", path.display())),
        Err(e) => ToolOutcome::err(format!("Couldn't open it: {e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn temp_project(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("eaon_tool_test_{name}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn device_tool_gates_hold() {
        // App names: plain names pass, shell metacharacters and traversal don't.
        assert!(valid_app_name("Firefox"));
        assert!(valid_app_name("Visual Studio Code"));
        assert!(valid_app_name("notepad.exe"));
        assert!(!valid_app_name("firefox; rm -rf ~"));
        assert!(!valid_app_name("../../bin/sh"));
        assert!(!valid_app_name("a&b"));
        assert!(!valid_app_name(""));

        // open_url: only http(s) may reach the OS opener.
        let bad = open_url(&json!({"url": "file:///etc/passwd"}));
        assert!(!bad.ok && bad.text.contains("http"));
        let scheme = open_url(&json!({"url": "javascript:alert(1)"}));
        assert!(!scheme.ok);

        // trash_item: refuses system locations outright.
        let refused = trash_item(&json!({"path": if cfg!(windows) { "C:\\Windows\\notepad.exe" } else { "/usr/bin/env" }}));
        assert!(!refused.ok && refused.text.contains("Refused"));

        // trash_item works on a real temp file (recoverable delete).
        let dir = temp_project("trash");
        let victim = dir.join("bye.txt");
        std::fs::write(&victim, "x").unwrap();
        let ok = trash_item(&json!({"path": victim.to_string_lossy()}));
        assert!(ok.ok, "{}", ok.text);
        assert!(!victim.exists());
    }

    #[test]
    fn refuses_system_paths() {
        // A protected root must never be modifiable.
        let sys = if cfg!(windows) { "C:\\Windows\\System32\\x.txt" } else { "/usr/bin/x" };
        let out = write_file(&json!({ "path": sys, "content": "x" }));
        assert!(!out.ok, "must refuse writing to system path");
        assert!(out.text.contains("Refused"));
    }

    #[test]
    fn refuses_parent_escape() {
        // A ~/../../etc/passwd style escape normalizes out of home → refused.
        let out = write_file(&json!({ "path": "~/../../../../etc/passwd", "content": "x" }));
        assert!(!out.ok, "must refuse an escape above home");
    }

    #[test]
    fn write_read_edit_roundtrip() {
        let dir = temp_project("roundtrip");
        let file = dir.join("main.py").to_string_lossy().to_string();

        let w = write_file(&json!({ "path": &file, "content": "print('a')\nprint('b')\n" }));
        assert!(w.ok, "write failed: {}", w.text);

        let r = read_file(&json!({ "path": &file }));
        assert!(r.ok && r.text.contains("print('a')"));

        let e = edit_file(&json!({ "path": &file, "search": "print('a')", "replace": "print('z')" }));
        assert!(e.ok, "edit failed: {}", e.text);
        let after = std::fs::read_to_string(&file).unwrap();
        assert!(after.contains("print('z')") && !after.contains("print('a')"));

        // Ambiguous edit (2 occurrences) must be refused.
        std::fs::write(&file, "x\nx\n").unwrap();
        let bad = edit_file(&json!({ "path": &file, "search": "x", "replace": "y" }));
        assert!(!bad.ok, "must refuse a non-unique edit");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn search_and_find_work_and_skip_noise() {
        let dir = temp_project("search");
        std::fs::write(dir.join("app.rs"), "fn handle_login() {}\nlet x = 1;\n").unwrap();
        std::fs::write(dir.join("util.rs"), "fn helper() {}\n").unwrap();
        // A noise dir that must be skipped.
        std::fs::create_dir_all(dir.join("node_modules")).unwrap();
        std::fs::write(dir.join("node_modules").join("junk.rs"), "fn handle_login() {}\n").unwrap();

        let s = search_code(&json!({ "pattern": "fn handle_login", "path": dir.to_string_lossy() }));
        assert!(s.ok, "{}", s.text);
        assert!(s.text.contains("app.rs:1"), "should find the real hit: {}", s.text);
        assert!(!s.text.contains("node_modules"), "must skip noise dirs: {}", s.text);

        let f = find_files(&json!({ "path": dir.to_string_lossy(), "name_pattern": "*.rs" }));
        assert!(f.ok && f.text.contains("app.rs") && f.text.contains("util.rs"));
        assert!(!f.text.contains("junk.rs"), "find must skip noise dirs too");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn shell_runs_and_blocks_escalation() {
        let echo = run_shell(&json!({ "command": "echo eaon_ok" }));
        assert!(echo.ok, "echo failed: {}", echo.text);
        assert!(echo.text.contains("eaon_ok"));

        let sudo = run_shell(&json!({ "command": "sudo rm -rf /" }));
        assert!(!sudo.ok, "must refuse sudo");
        assert!(sudo.text.contains("Refused"));
    }
}
