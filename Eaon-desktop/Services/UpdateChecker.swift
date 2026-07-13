import AppKit
import Foundation
import SwiftUI

/// The app's own version identity. The dev build is a bare executable with
/// no Info.plist, so `Bundle.main`'s CFBundleShortVersionString is always
/// nil — this constant is the single source of truth instead. Bump it as
/// the LAST step of cutting a release, so a freshly-updated app never
/// thinks the manifest's version is still newer than itself.
enum AppVersion {
    static let current = "2026.1.9"
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
/// the download + self-install when the user asks for it.
///
/// Design constraints this deliberately respects:
/// - A failed or unreachable check is a silent no-op — an update prompt is
///   the only acceptable outcome of a background check, never an error.
/// - "Update Now" downloads a .zip of the new .app and hands it to
///   `SelfUpdateInstaller`, which verifies it's a real, complete Eaon
///   bundle before touching anything on disk, then swaps it in with an
///   automatic rollback if the swap itself fails. See that type for the
///   actual safety mechanics — the goal is that a bad download or an
///   interrupted install can never leave the app broken or missing.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// Where the manifest lives — hosted alongside the .dmg downloads on
    /// downloads.eaon.dev. Until this URL is real, checks fail silently and
    /// the app simply never prompts.
    static let manifestURL = URL(string: "https://downloads.eaon.dev/update-manifest.json")!

    enum DownloadState: Equatable {
        case idle
        case downloading(fraction: Double?)
        case installing
        case relaunching
        case failed(String)
    }

    /// Non-nil exactly while the "New Version" card should be showing.
    private(set) var available: UpdateManifest?
    private(set) var downloadState: DownloadState = .idle
    /// One-line outcome of a user-initiated check, for Settings → General
    /// ("You're up to date", "Couldn't reach the update server", …).
    private(set) var lastManualCheckResult: String?
    var isCheckingManually = false

    /// Whether Eaon checks for updates on its own — at launch and
    /// periodically after that — versus only when the user presses "Check
    /// for Updates" by hand. Defaults to true (matching the only behavior
    /// this app had before this setting existed), same pattern as
    /// `MemoryStore.isAutoLearnEnabled`.
    var isAutoCheckEnabled: Bool {
        didSet {
            guard isAutoCheckEnabled != oldValue else { return }
            UserDefaults.standard.set(isAutoCheckEnabled, forKey: Self.autoCheckEnabledKey)
            startPeriodicChecksIfNeeded()
        }
    }

    private let snoozedVersionKey = "update_snoozed_version"
    private let snoozeUntilKey = "update_snooze_until"
    private static let autoCheckEnabledKey = "eaon_update_autocheck_enabled"
    private static let periodicCheckInterval: UInt64 = 6 * 60 * 60 * 1_000_000_000

    private var periodicCheckTask: Task<Void, Never>?

    private init() {
        isAutoCheckEnabled = UserDefaults.standard.object(forKey: Self.autoCheckEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.autoCheckEnabledKey)
    }

    // MARK: - Checking

    /// Background check (launch): silent unless a genuinely newer,
    /// non-snoozed version exists. Also starts the recurring check that
    /// keeps running for as long as the app stays open, so "periodically"
    /// is real and not just launch-time copy.
    func checkOnLaunch() async {
        startPeriodicChecksIfNeeded()
        guard isAutoCheckEnabled else { return }
        await silentCheck()
    }

    /// Runs every `periodicCheckInterval` while the app is open and the
    /// setting is on; cancelled and restarted whenever the toggle flips so
    /// turning it off takes effect immediately rather than after the next
    /// scheduled tick.
    private func startPeriodicChecksIfNeeded() {
        periodicCheckTask?.cancel()
        guard isAutoCheckEnabled else { return }
        periodicCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.periodicCheckInterval)
                guard !Task.isCancelled, let self else { return }
                await self.silentCheck()
            }
        }
    }

    private func silentCheck() async {
        guard let manifest = await fetchManifest() else { return }
        guard Self.isVersion(manifest.latestVersion, newerThan: AppVersion.current) else { return }
        guard !isSnoozed(manifest.latestVersion) else { return }
        withAnimation(.uiEaseOut(duration: 0.45)) { available = manifest }
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
            withAnimation(.uiEaseOut(duration: 0.45)) { available = manifest }
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
        withAnimation(.uiEaseOut(duration: 0.35)) { self.available = nil }
        downloadState = .idle
    }

    private func isSnoozed(_ version: String) -> Bool {
        guard UserDefaults.standard.string(forKey: snoozedVersionKey) == version,
              let until = UserDefaults.standard.object(forKey: snoozeUntilKey) as? Date else { return false }
        return Date() < until
    }

    /// Downloads the release .zip (with live progress when the server
    /// reports a length), verifies and installs it in place, then relaunches
    /// — no manual quit-and-drag required. Falls back to a clear error
    /// message, with the current app left untouched, if anything along the
    /// way can't be trusted.
    func updateNow() {
        guard let manifest = available else { return }
        switch downloadState {
        case .downloading, .installing, .relaunching: return
        case .idle, .failed: break
        }

        Task {
            do {
                downloadState = .downloading(fraction: nil)
                let zipURL = try await download(manifest: manifest)
                downloadState = .installing
                try await SelfUpdateInstaller.install(zipAt: zipURL)
                downloadState = .relaunching
                // Let the UI show "Restarting…" for a beat before the app vanishes.
                try? await Task.sleep(nanoseconds: 500_000_000)
                SelfUpdateInstaller.relaunchAndQuit()
            } catch {
                downloadState = .failed(Self.userMessage(for: error))
            }
        }
    }

    private static func userMessage(for error: Error) -> String {
        if let installError = error as? SelfUpdateInstaller.InstallError {
            return installError.errorDescription ?? "Update failed."
        }
        return "Download failed — \(error.localizedDescription)"
    }

    private func download(manifest: UpdateManifest) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: manifest.downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("EaonDownload-\(UUID().uuidString).zip")
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
            written += Int64(buffer.count)
        }

        // A truncated download must never reach the installer — ditto would
        // either fail loudly or, worse, partially succeed on garbage.
        if expected > 0, written != expected {
            try? FileManager.default.removeItem(at: destination)
            throw URLError(.zeroByteResource)
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
