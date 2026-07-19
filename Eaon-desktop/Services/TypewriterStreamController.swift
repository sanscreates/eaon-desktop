import Foundation

@MainActor
final class TypewriterStreamController {
    private var characters: [Character] = []
    private var displayedCount = 0
    private var streamFinished = false
    private var typingTask: Task<Void, Never>?

    private var recentArrivalRate: Double = 48
    private var lastAppendDate: Date?

    private let onDisplayUpdate: (String) -> Void
    /// True for callers that want the raw stream as it actually arrives —
    /// the local API server relaying to an external HTTP client, which
    /// should see real network-speed deltas, not the chat UI's deliberate
    /// typing-reveal animation. Skips the throttled reveal loop entirely:
    /// every `append` reflects immediately.
    private let instant: Bool

    init(instant: Bool = false, onDisplayUpdate: @escaping (String) -> Void) {
        self.instant = instant
        self.onDisplayUpdate = onDisplayUpdate
    }

    var hasContent: Bool {
        !characters.isEmpty
    }

    private var backlog: Int {
        characters.count - displayedCount
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }

        let now = Date()
        if let lastAppendDate, !chunk.isEmpty {
            let elapsed = now.timeIntervalSince(lastAppendDate)
            if elapsed > 0.001 {
                let instantRate = Double(chunk.count) / elapsed
                recentArrivalRate = recentArrivalRate * 0.6 + instantRate * 0.4
            }
        }
        lastAppendDate = now

        characters.append(contentsOf: chunk)

        if instant {
            displayedCount = characters.count
            onDisplayUpdate(String(characters))
            return
        }
        startTypingIfNeeded()
    }

    func markStreamFinished() {
        streamFinished = true
    }

    func waitUntilCaughtUp() async {
        guard !instant else { return }

        while displayedCount < characters.count {
            try? await Task.sleep(for: Self.tick)
        }

        while typingTask != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func cancel() {
        typingTask?.cancel()
        typingTask = nil
        streamFinished = true
        displayedCount = characters.count
        onDisplayUpdate(String(characters))
    }

    /// One reveal per ~display frame, never faster. The old loop shrank the
    /// DELAY as backlog grew (down to 3ms — ~330 updates/s), but every
    /// update here is a full `messages` mutation: the transcript re-diffs,
    /// the streaming cell re-parses its whole content, the context badge
    /// re-walks the conversation, and the follow-scroll re-resolves layout.
    /// A display shows at most 120 of those a second, and text reveal reads
    /// as continuous well below that — so past ~60Hz the extra updates were
    /// pure invisible CPU burn (measured live as the main thread saturating
    /// during fast streams: the reported scroll lag). Same chars-per-second
    /// reveal rates as before, expressed as bigger steps at a fixed 16ms
    /// tick instead of small steps at a frantic one.
    private static let tick = Duration.milliseconds(16)

    private func startTypingIfNeeded() {
        guard typingTask == nil else { return }

        typingTask = Task {
            while !Task.isCancelled {
                let pending = backlog

                if pending > 0 {
                    let step = revealStep(for: pending)
                    displayedCount = min(characters.count, displayedCount + step)
                    onDisplayUpdate(String(characters.prefix(displayedCount)))
                    try? await Task.sleep(for: Self.tick)
                } else if streamFinished {
                    break
                } else {
                    try? await Task.sleep(for: .milliseconds(12))
                }
            }
            typingTask = nil
        }
    }

    /// Characters to reveal this tick — the same effective chars/sec the
    /// old step-and-delay pairs produced (faster arrival or a growing
    /// backlog still accelerates the reveal), just re-expressed at the
    /// fixed frame-rate tick.
    private func revealStep(for pending: Int) -> Int {
        let speed = max(20, min(420, recentArrivalRate))
        let speedFactor = speed / 120

        let perSecond: Double
        if pending > 300 {
            perSecond = 3400 + 6000 * speedFactor
        } else if pending > 100 {
            perSecond = 800 + 1600 * speedFactor
        } else if pending > 25 {
            perSecond = 400 + 600 * speedFactor
        } else {
            perSecond = speed
        }
        return min(pending, max(1, Int(perSecond * 0.016)))
    }
}
