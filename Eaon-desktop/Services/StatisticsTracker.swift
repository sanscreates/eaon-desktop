import Foundation

struct PromptEvent: Codable, Identifiable {
    var id: UUID = UUID()
    let date: Date
    let modelId: String
}

struct TokenUsageEvent: Codable, Identifiable {
    var id: UUID = UUID()
    let date: Date
    let modelId: String
    let tokens: Int
}

struct ModelSpeedSample: Codable, Identifiable {
    var id: UUID = UUID()
    let date: Date
    let modelId: String
    let tokensPerSecond: Double
    let latencySeconds: Double
    let tokenCount: Int
}

@MainActor
@Observable
final class StatisticsTracker {
    static let shared = StatisticsTracker()

    private(set) var sessionStart = Date()
    private(set) var sessionGeneratedTokens = 0
    private(set) var promptEvents: [PromptEvent] = []
    private(set) var tokenUsageEvents: [TokenUsageEvent] = []

    private var recentPromptTimes: [Date] = []
    private var recentTokenSamples: [(date: Date, tokens: Int)] = []
    private var tpmHistory: [Double] = Array(repeating: 0, count: 30)

    var connectionState: String = "idle"
    var syncState: String = "idle"
    var isOnline: Bool = true

    var currentMessageCount: Int = 0
    var currentUserMessageCount: Int = 0
    var currentAIMessageCount: Int = 0
    var currentCharacterCount: Int = 0
    var currentApproxTokens: Int = 0
    var draftLength: Int = 0
    var selectedEngine: String = "None selected"
    var isGenerating: Bool = false
    var hasActiveChat: Bool = false
    var totalChats: Int = 0
    var totalAllCharacters: Int = 0
    var totalAllApproxTokens: Int = 0

    private let eventsKey      = "statistics_prompt_events"
    private let tokenEventKey  = "statistics_token_usage_events"
    private let speedSampleKey = "statistics_speed_samples"

    private(set) var speedSamples: [ModelSpeedSample] = []

    // The model currently generating (set by ChatViewModel during streaming)
    var currentGeneratingModel: String = ""

    private init() {
        loadEvents()
    }

    // MARK: - Live metrics

    var sessionUptime: TimeInterval {
        Date().timeIntervalSince(sessionStart)
    }

    var liveRPM: Int {
        let cutoff = Date().addingTimeInterval(-60)
        return recentPromptTimes.filter { $0 >= cutoff }.count
    }

    var liveTPM: Int {
        let cutoff = Date().addingTimeInterval(-60)
        return recentTokenSamples.filter { $0.date >= cutoff }.reduce(0) { $0 + $1.tokens }
    }

    var tokensPerSecond: Double {
        let cutoff = Date().addingTimeInterval(-5)
        let tokens = recentTokenSamples.filter { $0.date >= cutoff }.reduce(0) { $0 + $1.tokens }
        return Double(tokens) / 5.0
    }

    func tickTPMHistory() {
        tpmHistory.removeFirst()
        tpmHistory.append(Double(liveTPM))
    }

    var tpmChartValues: [Double] {
        tpmHistory
    }

    // MARK: - Recording

    func recordUserPrompt(modelId: String) {
        let now = Date()
        recentPromptTimes.append(now)
        pruneRecentSamples()

        let event = PromptEvent(date: now, modelId: modelId)
        promptEvents.append(event)
        saveEvents()
    }

    func recordGeneratedCharacters(_ count: Int) {
        guard count > 0 else { return }
        let tokens = Self.approxTokens(characters: count)
        sessionGeneratedTokens += tokens
        recentTokenSamples.append((date: Date(), tokens: tokens))
        if !currentGeneratingModel.isEmpty {
            let evt = TokenUsageEvent(date: Date(), modelId: currentGeneratingModel, tokens: tokens)
            tokenUsageEvents.append(evt)
            saveTokenEvents()
        }
        pruneRecentSamples()
    }

    // MARK: - Token usage queries

    func tokenUsage(in range: ClosedRange<Date>) -> [TokenUsageEvent] {
        tokenUsageEvents.filter { range.contains($0.date) }
    }

    func tokensByModel(in range: ClosedRange<Date>) -> [(modelId: String, tokens: Int)] {
        let grouped = Dictionary(grouping: tokenUsage(in: range)) { $0.modelId }
        return grouped
            .map { (modelId: $0.key, tokens: $0.value.reduce(0) { $0 + $1.tokens }) }
            .sorted { $0.tokens > $1.tokens }
    }

    func tokensByDay(in range: ClosedRange<Date>) -> [(date: Date, tokens: Int)] {
        let cal = Calendar.current
        var counts: [Date: Int] = [:]
        for evt in tokenUsage(in: range) {
            let day = cal.startOfDay(for: evt.date)
            counts[day, default: 0] += evt.tokens
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    func totalTokens(in range: ClosedRange<Date>) -> Int {
        tokenUsage(in: range).reduce(0) { $0 + $1.tokens }
    }

    // MARK: - Speed tracking

    func recordCompletionSpeed(modelId: String, tokensPerSecond: Double, latency: Double, tokenCount: Int) {
        guard tokenCount > 10, tokensPerSecond > 0 else { return }
        let sample = ModelSpeedSample(
            date: Date(),
            modelId: modelId,
            tokensPerSecond: tokensPerSecond,
            latencySeconds: latency,
            tokenCount: tokenCount
        )
        speedSamples.append(sample)
        // Keep last 500 samples max
        if speedSamples.count > 500 { speedSamples.removeFirst(speedSamples.count - 500) }
        saveSpeedSamples()
    }

    func speedStats(for modelId: String) -> (avgTPS: Double, avgLatency: Double, sampleCount: Int)? {
        let samples = speedSamples.filter { $0.modelId == modelId }
        guard !samples.isEmpty else { return nil }
        let avgTPS     = samples.map(\.tokensPerSecond).reduce(0, +) / Double(samples.count)
        let avgLatency = samples.map(\.latencySeconds).reduce(0, +) / Double(samples.count)
        return (avgTPS, avgLatency, samples.count)
    }

    /// All model IDs for which we have speed samples, ranked by avg TPS descending.
    func speedLeaderboard() -> [(modelId: String, avgTPS: Double, avgLatency: Double, sampleCount: Int)] {
        let ids = Set(speedSamples.map(\.modelId))
        return ids.compactMap { id -> (String, Double, Double, Int)? in
            guard let s = speedStats(for: id) else { return nil }
            return (id, s.avgTPS, s.avgLatency, s.sampleCount)
        }
        .sorted { $0.1 > $1.1 }
    }

    func syncChatState(
        messages: [ChatMessage],
        draft: String,
        modelId: String,
        modelName: String?,
        generating: Bool
    ) {
        currentMessageCount = messages.count
        currentUserMessageCount = messages.filter(\.isUser).count
        currentAIMessageCount = messages.filter { !$0.isUser && !$0.isError }.count
        currentCharacterCount = messages.reduce(0) { $0 + $1.content.count }
        currentApproxTokens = Self.approxTokens(characters: currentCharacterCount)
        draftLength = draft.count
        hasActiveChat = !messages.isEmpty
        isGenerating = generating
        connectionState = generating ? "streaming" : "idle"
        syncState = "idle"

        if modelId.isEmpty {
            selectedEngine = "None selected"
        } else if let modelName, !modelName.isEmpty {
            selectedEngine = modelName
        } else {
            selectedEngine = modelId
        }

        totalChats = messages.isEmpty ? 0 : 1
        totalAllCharacters = currentCharacterCount
        totalAllApproxTokens = currentApproxTokens
    }

    // MARK: - Range queries

    func prompts(in range: ClosedRange<Date>) -> [PromptEvent] {
        promptEvents.filter { range.contains($0.date) }
    }

    func promptsByModel(in range: ClosedRange<Date>) -> [(modelId: String, count: Int)] {
        let grouped = Dictionary(grouping: prompts(in: range)) { $0.modelId }
        return grouped
            .map { (modelId: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    func promptsByDay(in range: ClosedRange<Date>) -> [(date: Date, count: Int)] {
        let calendar = Calendar.current
        var counts: [Date: Int] = [:]
        for event in prompts(in: range) {
            let day = calendar.startOfDay(for: event.date)
            counts[day, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    func weekdayCounts(in range: ClosedRange<Date>) -> [Int] {
        let calendar = Calendar.current
        var counts = Array(repeating: 0, count: 7)
        for event in prompts(in: range) {
            let weekday = calendar.component(.weekday, from: event.date)
            let index = (weekday + 5) % 7 // Mon=0 … Sun=6
            counts[index] += 1
        }
        return counts
    }

    func mostActiveWeekday(in range: ClosedRange<Date>) -> (name: String, count: Int) {
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        let counts = weekdayCounts(in: range)
        guard let maxCount = counts.max(), maxCount > 0,
              let index = counts.firstIndex(of: maxCount) else {
            return ("—", 0)
        }
        return (names[index], maxCount)
    }

    static func approxTokens(characters: Int) -> Int {
        max(0, Int(ceil(Double(characters) / 4.0)))
    }

    static func formatUptime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func pruneRecentSamples() {
        let cutoff = Date().addingTimeInterval(-120)
        recentPromptTimes.removeAll { $0 < cutoff }
        recentTokenSamples.removeAll { $0.date < cutoff }
    }

    private func loadEvents() {
        if let data = UserDefaults.standard.data(forKey: eventsKey),
           let decoded = try? JSONDecoder().decode([PromptEvent].self, from: data) {
            promptEvents = decoded
        }
        if let data = UserDefaults.standard.data(forKey: tokenEventKey),
           let decoded = try? JSONDecoder().decode([TokenUsageEvent].self, from: data) {
            tokenUsageEvents = decoded
        }
        if let data = UserDefaults.standard.data(forKey: speedSampleKey),
           let decoded = try? JSONDecoder().decode([ModelSpeedSample].self, from: data) {
            speedSamples = decoded
        }
    }

    private func saveSpeedSamples() {
        if let data = try? JSONEncoder().encode(speedSamples) {
            UserDefaults.standard.set(data, forKey: speedSampleKey)
        }
    }

    private func saveEvents() {
        if let data = try? JSONEncoder().encode(promptEvents) {
            UserDefaults.standard.set(data, forKey: eventsKey)
        }
    }

    private func saveTokenEvents() {
        if let data = try? JSONEncoder().encode(tokenUsageEvents) {
            UserDefaults.standard.set(data, forKey: tokenEventKey)
        }
    }
}
