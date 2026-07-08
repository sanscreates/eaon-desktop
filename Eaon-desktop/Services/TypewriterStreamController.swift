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

    init(onDisplayUpdate: @escaping (String) -> Void) {
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
        startTypingIfNeeded()
    }

    func markStreamFinished() {
        streamFinished = true
    }

    func waitUntilCaughtUp() async {
        while displayedCount < characters.count {
            try? await Task.sleep(for: tickDelay())
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

    private func startTypingIfNeeded() {
        guard typingTask == nil else { return }

        typingTask = Task {
            while !Task.isCancelled {
                let pending = backlog

                if pending > 0 {
                    let step = revealStep(for: pending)
                    displayedCount = min(characters.count, displayedCount + step)
                    onDisplayUpdate(String(characters.prefix(displayedCount)))
                    try? await Task.sleep(for: tickDelay())
                } else if streamFinished {
                    break
                } else {
                    try? await Task.sleep(for: .milliseconds(12))
                }
            }
            typingTask = nil
        }
    }

    /// Reveal more characters per tick when the model streams faster or backlog grows.
    private func revealStep(for pending: Int) -> Int {
        let speed = max(20, min(420, recentArrivalRate))
        let speedFactor = speed / 120

        if pending > 300 {
            return min(pending, Int(10 + speedFactor * 18))
        }
        if pending > 100 {
            return min(pending, Int(4 + speedFactor * 8))
        }
        if pending > 25 {
            return min(pending, Int(2 + speedFactor * 3))
        }
        return 1
    }

    private func tickDelay() -> Duration {
        let pending = backlog
        let speed = max(20, min(420, recentArrivalRate))

        if pending == 0 {
            return .milliseconds(12)
        }

        if pending > 250 {
            return .milliseconds(3)
        }
        if pending > 80 {
            return .milliseconds(5)
        }

        let milliseconds = Int(1000 / speed)
        return .milliseconds(max(4, min(16, milliseconds)))
    }
}
