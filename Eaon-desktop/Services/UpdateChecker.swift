import AppKit
import Foundation

/// The app's own version identity. The dev build is a bare executable with
/// no Info.plist, so `Bundle.main`'s CFBundleShortVersionString is always
/// nil — this constant is the single source of truth instead. Bump it as
/// the LAST step of cutting a release, so a freshly-updated app never
/// thinks the manifest's version is still newer than itself.
enum AppVersion {
    static let current = "0.8.2"
}

/// What the update server hosts — one small JSON file describing the newest
/// release. See `update-manifest.sample.json` at the repo root for the
/// exact shape and RELEASING-UPDATES.md for the release steps.
struct UpdateManifest: Decodable, Equatable {
    let latestVersion: String
    let downloadURL: URL
    /// Optional — the card's "Show Release Notes" simply hides when absent.
    let releaseNotes: String?
}

/// Checks for updates on launch, drives the "New Version" card, and runs
/// the download when the user asks for it.
///
/// Design constraints this deliberately respects:
/// - A failed or unreachable check is a silent no-op — an update prompt is
///   the only acceptable outcome of a background check, never an error.
/// - "Update Now" downloads the release and opens it. It does NOT try to
///   silently replace the running binary: that only becomes safe once the
///   app ships as a signed .app bundle (at which point Sparkle, the
///   standard framework for this, is the right tool — it adds the signed
///   appcast + atomic-swap + relaunch machinery this hand-rolled version
///   deliberately doesn't attempt). Until then, trusting an unsigned
///   download enough to self-replace would be a security hole, not a
///   feature.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// Where the manifest lives. Point this at wherever the release JSON is
    /// actually hosted (any static host works — GitHub raw/releases, the
    /// aquadevs.com site itself, an S3 bucket…). Until this URL is real,
    /// checks fail silently and the app simply never prompts.
    static let manifestURL = URL(string: "https://aquadevs.com/aquachat/update-manifest.json")!

    enum DownloadState: Equatable {
        case idle
        case downloading(fraction: Double?)
        case opened(filename: String)
        case failed(String)
    }

    /// Non-nil exactly while the "New Version" card should be showing.
    private(set) var available: UpdateManifest?
    private(set) var downloadState: DownloadState = .idle
    /// One-line outcome of a user-initiated check, for Settings → General
    /// ("You're up to date", "Couldn't reach the update server", …).
    private(set) var lastManualCheckResult: String?
    var isCheckingManually = false

    private let snoozedVersionKey = "update_snoozed_version"
    private let snoozeUntilKey = "update_snooze_until"

    private init() {}

    // MARK: - Checking

    /// Background check (launch): silent unless a genuinely newer,
    /// non-snoozed version exists.
    func checkOnLaunch() async {
        guard let manifest = await fetchManifest() else { return }
        guard Self.isVersion(manifest.latestVersion, newerThan: AppVersion.current) else { return }
        guard !isSnoozed(manifest.latestVersion) else { return }
        available = manifest
    }

    /// User-initiated check (Settings): always reports an outcome, and an
    /// explicit ask overrides any earlier "Remind Me Later" snooze.
    func checkManually() async {
        isCheckingManually = true
        defer { isCheckingManually = false }
        lastManualCheckResult = nil

        guard let manifest = await fetchManifest() else {
            lastManualCheckResult = "Couldn't reach the update server. Try again later."
            return
        }
        if Self.isVersion(manifest.latestVersion, newerThan: AppVersion.current) {
            available = manifest
            lastManualCheckResult = "Version \(manifest.latestVersion) is available."
        } else {
            lastManualCheckResult = "You're up to date — \(AppVersion.current) is the latest version."
        }
    }

    private func fetchManifest() async -> UpdateManifest? {
        var request = URLRequest(url: Self.manifestURL)
        request.timeoutInterval = 10
        // Always hit the origin — a stale cached manifest could re-announce
        // an update the user already installed.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data) else { return nil }
        return manifest
    }

    // MARK: - Card actions

    /// Hides the card and stays quiet about THIS version for 24 hours.
    /// A different (even newer) version published during the snooze still
    /// prompts — the snooze is per-version, not a global mute.
    func remindLater() {
        guard let available else { return }
        UserDefaults.standard.set(available.latestVersion, forKey: snoozedVersionKey)
        UserDefaults.standard.set(Date().addingTimeInterval(24 * 60 * 60), forKey: snoozeUntilKey)
        self.available = nil
        downloadState = .idle
    }

    private func isSnoozed(_ version: String) -> Bool {
        guard UserDefaults.standard.string(forKey: snoozedVersionKey) == version,
              let until = UserDefaults.standard.object(forKey: snoozeUntilKey) as? Date else { return false }
        return Date() < until
    }

    /// Downloads the release into ~/Downloads (with live progress when the
    /// server reports a length) and opens it when done — for a .dmg that
    /// mounts the installer, leaving one drag for the user.
    func updateNow() {
        guard let manifest = available, downloadState != .downloading(fraction: nil) else { return }
        if case .downloading = downloadState { return }

        Task {
            downloadState = .downloading(fraction: nil)
            do {
                let fileURL = try await download(manifest: manifest)
                downloadState = .opened(filename: fileURL.lastPathComponent)
                NSWorkspace.shared.open(fileURL)
            } catch {
                downloadState = .failed("Download failed — \(error.localizedDescription)")
            }
        }
    }

    private func download(manifest: UpdateManifest) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: manifest.downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let suggested = response.suggestedFilename ?? "Eaon-\(manifest.latestVersion).dmg"
        let destination = downloads.appendingPathComponent(suggested)
        // A leftover file from an earlier attempt shouldn't fail the retry.
        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let expected = response.expectedContentLength
        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 256 * 1024 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 {
                    downloadState = .downloading(fraction: Double(written) / Double(expected))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        return destination
    }

    // MARK: - Version comparison

    /// Numeric dot-component comparison ("0.8.10" > "0.8.3", unlike string
    /// order), padding the shorter side with zeros ("1.0" == "1.0.0").
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
