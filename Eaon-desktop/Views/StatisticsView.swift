import SwiftUI

enum StatisticsTab: String, CaseIterable, Identifiable {
    case usage = "Usage"
    case cost  = "Cost"
    var id: String { rawValue }
}

struct StatisticsView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var chatViewModel: ChatViewModel
    @Bindable private var tracker = StatisticsTracker.shared
    @Bindable private var appearance = AppearanceSettings.shared

    @AppStorage("nerd_hud_enabled") private var nerdHUDEnabled = false
    @State private var rangeStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var rangeEnd = Date()
    @State private var now = Date()
    @State private var activeTab: StatisticsTab = .usage

    private let weekdayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private var dateRange: ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: rangeStart)
        let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: rangeEnd) ?? rangeEnd
        return start...end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch activeTab {
                    case .usage:
                        nerdToggleRow
                        liveChartCard
                        HStack(alignment: .top, spacing: 12) {
                            runtimePanel
                            currentChatPanel
                            enginePanel
                        }
                        disclaimer
                        dateRangeCard
                        usagePatternCard
                        HStack(spacing: 12) {
                            summaryTile("Total Chats", value: tracker.totalChats)
                            summaryTile("Total Prompts", value: tracker.prompts(in: dateRange).count)
                        }
                        promptsByModelCard
                        mostActiveDayCard

                    case .cost:
                        dateRangeCard
                        costOverviewCard
                        costByModelCard
                        costByDayCard
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.backgroundPrimary)
        .onAppear { refreshChatSnapshot() }
        .onChange(of: chatViewModel.messages.count) { _, _ in refreshChatSnapshot() }
        .onChange(of: chatViewModel.inputText) { _, _ in refreshChatSnapshot() }
        .onChange(of: chatViewModel.selectedModel) { _, _ in refreshChatSnapshot() }
        .onChange(of: chatViewModel.isGenerating) { _, _ in refreshChatSnapshot() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { tick in
            now = tick
            tracker.tickTPMHistory()
            refreshChatSnapshot()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Statistics")
                    .font(AppFont.mono(20, weight: .bold))
                    .foregroundColor(colors.textPrimary)
                Text("View your usage statistics and activity.")
                    .font(AppFont.sans(13))
                    .foregroundColor(colors.textSecondary)
            }
            Spacer()
            // Tab picker
            HStack(spacing: 0) {
                ForEach(StatisticsTab.allCases) { tab in
                    Button {
                        activeTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(AppFont.mono(12, weight: .semibold))
                            .foregroundColor(activeTab == tab ? colors.textPrimary : colors.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(activeTab == tab ? colors.backgroundSelected : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(colors.backgroundInputSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    // MARK: - Live section

    private var nerdToggleRow: some View {
        HStack(spacing: 14) {
            Toggle(isOn: $nerdHUDEnabled) {
                Text("Stats for Nerds (Live)")
                    .font(AppFont.mono(13, weight: .medium))
                        .foregroundColor(colors.textPrimary.opacity(0.85))
            }
            .toggleStyle(.checkbox)

            if nerdHUDEnabled {
                Divider().frame(height: 14)

                Text("Position")
                    .font(AppFont.mono(12))
                    .foregroundColor(colors.textSecondary)

                Picker("", selection: $appearance.notificationPosition) {
                    ForEach(NotificationPosition.allCases) { pos in
                        Text(pos.rawValue).tag(pos)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        .animation(.easeOut(duration: 0.15), value: nerdHUDEnabled)
    }

    private var liveChartCard: some View {
        StatSurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("LIVE MOVING CHART (TPM)")
                        .font(AppFont.mono(10, weight: .semibold))
                        .foregroundColor(colors.textSecondary)
                        .tracking(0.5)
                    Spacer()
                    Text("RPM: \(tracker.liveRPM) · TPM: \(tracker.liveTPM) · tok/s: \(Int(tracker.tokensPerSecond))")
                        .font(AppFont.mono(11))
                        .foregroundColor(colors.textSecondary)
                }

                TPMLineChartView(values: tracker.tpmChartValues)
                    .frame(height: 110)
            }
            .padding(14)
        }
    }

    // MARK: - Three-column panels

    private var runtimePanel: some View {
        StatSurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("RUNTIME")
                headline("Session Uptime: \(StatisticsTracker.formatUptime(tracker.sessionUptime))")
                metricLine("Live RPM", "\(tracker.liveRPM)")
                metricLine("Live TPM", "\(tracker.liveTPM)")
                metricLine("Tokens/sec", String(format: "%.0f", tracker.tokensPerSecond))
                badgeRow("Online", tracker.isOnline ? "Yes" : "No", style: .success)
                badgeRow("Connection", tracker.connectionState, style: .idle)
                badgeRow("Sync", tracker.syncState, style: .idle)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var currentChatPanel: some View {
        StatSurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("CURRENT CHAT")
                headline(tracker.hasActiveChat ? "Active chat" : "No active chat")
                metricLine("Messages", "\(tracker.currentMessageCount) (\(tracker.currentUserMessageCount) user / \(tracker.currentAIMessageCount) AI)")
                metricLine("Characters", "\(tracker.currentCharacterCount)")
                metricLine("Approx tokens (chat)", "\(tracker.currentApproxTokens)")
                metricLine("Draft length", "\(tracker.draftLength)")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var enginePanel: some View {
        StatSurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("ENGINE")
                headline(tracker.selectedEngine)
                metricLine("Storage mode", "local")
                metricLine("Total chats", "\(tracker.totalChats)")
                metricLine("Total characters (all chats)", "\(tracker.totalAllCharacters)")
                metricLine("Approx tokens (all chats)", "\(tracker.totalAllApproxTokens)")
                metricLine("Session generated tokens", "\(tracker.sessionGeneratedTokens)")
                metricLine("Generating", tracker.isGenerating ? "Yes" : "No")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var disclaimer: some View {
        Text("Token values are estimated in real time using a standard ~4 chars/token approximation.")
            .font(AppFont.sans(11))
            .foregroundColor(colors.textTertiary)
    }

    // MARK: - Historical section

    private var dateRangeCard: some View {
        StatSurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Date Range")
                    .font(AppFont.mono(13, weight: .semibold))
                    .foregroundColor(colors.textPrimary)

                HStack(spacing: 20) {
                    dateField("From:", selection: $rangeStart)
                    dateField("To:", selection: $rangeEnd)
                }

                HStack(spacing: 8) {
                    rangeButton("7 Days", days: -7)
                    rangeButton("30 Days", days: -30)
                    rangeButton("Today", todayOnly: true)
                }
            }
            .padding(14)
        }
    }

    private var usagePatternCard: some View {
        StatSurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(colors.backgroundSubtle)
                            .frame(width: 32, height: 32)
                        Image(systemName: "clock")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(colors.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Usage pattern")
                            .font(AppFont.mono(14, weight: .semibold))
                            .foregroundColor(colors.textPrimary)
                        Text("Prompts over the selected range, by model")
                            .font(AppFont.sans(12))
                            .foregroundColor(colors.textSecondary)
                    }
                }

                UsageGridChartView(data: tracker.promptsByDay(in: dateRange))
                    .frame(height: 140)
            }
            .padding(14)
        }
    }

    private var promptsByModelCard: some View {
        let byModel = tracker.promptsByModel(in: dateRange)
        return StatSurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.textSecondary)
                    Text("Prompts by Model")
                        .font(AppFont.mono(14, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                }

                if byModel.isEmpty {
                    Text("No usage data yet")
                        .font(AppFont.mono(13))
                        .foregroundColor(colors.textTertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(byModel, id: \.modelId) { item in
                        HStack {
                            Text(ModelCatalog.displayName(modelId: item.modelId, apiName: nil))
                                .font(AppFont.mono(13))
                                .foregroundColor(colors.textPrimary.opacity(0.8))
                            Spacer()
                            Text("\(item.count)")
                                .font(AppFont.mono(13, weight: .semibold))
                                .foregroundColor(Color(hex: "#4dabf7"))
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var mostActiveDayCard: some View {
        let weekday = tracker.mostActiveWeekday(in: dateRange)
        let counts = sundayFirstWeekdayCounts()

        return StatSurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.textSecondary)
                    Text("Most Active Day")
                        .font(AppFont.mono(14, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                }

                Text(weekday.name == "—" ? "—" : weekday.name)
                    .font(AppFont.mono(22, weight: .bold))
                    .foregroundColor(Color(hex: "#e8957a"))

                VStack(spacing: 8) {
                    ForEach(0..<7, id: \.self) { index in
                        weekdayBarRow(label: weekdayLabels[index], count: counts[index])
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: - Helpers

    private func refreshChatSnapshot() {
        let model = chatViewModel.chatModels.first { $0.id == chatViewModel.selectedModel }
        tracker.syncChatState(
            messages: chatViewModel.messages,
            draft: chatViewModel.inputText,
            modelId: chatViewModel.selectedModel,
            modelName: model?.name,
            generating: chatViewModel.isGenerating
        )
    }

    private func sundayFirstWeekdayCounts() -> [Int] {
        let monFirst = tracker.weekdayCounts(in: dateRange)
        guard monFirst.count == 7 else { return Array(repeating: 0, count: 7) }
        return [monFirst[6], monFirst[0], monFirst[1], monFirst[2], monFirst[3], monFirst[4], monFirst[5]]
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(AppFont.mono(10, weight: .semibold))
            .foregroundColor(colors.textTertiary)
            .tracking(0.6)
    }

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(AppFont.mono(15, weight: .semibold))
            .foregroundColor(colors.textPrimary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func metricLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .foregroundColor(colors.textSecondary)
            Text(value)
                .foregroundColor(colors.textPrimary.opacity(0.75))
        }
        .font(AppFont.mono(11))
    }

    private enum BadgeStyle { case success, idle }

    private func badgeRow(_ label: String, _ value: String, style: BadgeStyle) -> some View {
        HStack {
            Text("\(label):")
                .font(AppFont.mono(11))
                .foregroundColor(colors.textSecondary)
            Spacer()
            Text(value)
                .font(AppFont.mono(10, weight: .semibold))
                .foregroundColor(style == .success ? Color(hex: "#6ee7a0") : Color(hex: "#d4a574"))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(style == .success ? Color(hex: "#1a3d2e") : Color(hex: "#3d2e1a"))
                )
        }
    }

    private func summaryTile(_ title: String, value: Int) -> some View {
        StatSurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(AppFont.mono(12))
                    .foregroundColor(colors.textSecondary)
                Text("\(value)")
                    .font(AppFont.mono(36, weight: .bold))
                    .foregroundColor(Color(hex: "#4dabf7"))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dateField(_ label: String, selection: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(AppFont.mono(11))
                .foregroundColor(colors.textSecondary)
            DatePicker("", selection: selection, displayedComponents: .date)
                .labelsHidden()
        }
    }

    private func rangeButton(_ title: String, days: Int = 0, todayOnly: Bool = false) -> some View {
        Button(title) {
            if todayOnly {
                rangeStart = Calendar.current.startOfDay(for: Date())
                rangeEnd = Date()
            } else {
                rangeEnd = Date()
                rangeStart = Calendar.current.date(byAdding: .day, value: days, to: rangeEnd) ?? rangeEnd
            }
        }
        .buttonStyle(.plain)
        .font(AppFont.mono(11, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(colors.backgroundSubtle)
        .clipShape(Capsule())
        .foregroundColor(colors.textPrimary.opacity(0.75))
    }

    private func weekdayBarRow(label: String, count: Int) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(AppFont.mono(12))
                .foregroundColor(colors.textSecondary)
                .frame(width: 28, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                        Capsule()
                            .fill(colors.backgroundSubtle)
                    if count > 0 {
                        Capsule()
                            .fill(Color(hex: "#4dabf7").opacity(0.85))
                            .frame(width: max(8, geo.size.width * barFraction(for: count)))
                    }
                }
            }
            .frame(height: 8)

            Text("\(count)")
                .font(AppFont.mono(12))
                .foregroundColor(colors.textSecondary)
                .frame(width: 20, alignment: .trailing)
        }
        .frame(height: 16)
    }

    private func barFraction(for count: Int) -> CGFloat {
        let maxCount = max(sundayFirstWeekdayCounts().max() ?? 1, 1)
        return CGFloat(count) / CGFloat(maxCount)
    }
}

// MARK: - Cost cards (extension scope placed before private structs)

extension StatisticsView {
    var costOverviewCard: some View {
        let totalTok = tracker.totalTokens(in: dateRange)
        let allByModel = tracker.tokensByModel(in: dateRange)
        let totalCost = allByModel.reduce(0.0) { sum, entry in
            let tier = chatViewModel.availableModels.first { $0.id == entry.modelId }?.tier
            return sum + ModelPricingStore.estimatedCost(tokens: entry.tokens, modelId: entry.modelId, tier: tier)
        }

        return StatSurfaceCard {
            HStack(spacing: 0) {
                costStatCell("Tokens Generated", value: "\(totalTok)", icon: "number", color: Color(hex: "#4dabf7"))
                Divider().frame(height: 50)
                costStatCell("Est. Cost", value: ModelPricingStore.formatCost(totalCost), icon: "dollarsign.circle", color: Color(hex: "#6ee7a0"))
                Divider().frame(height: 50)
                costStatCell("Models Used", value: "\(allByModel.count)", icon: "cpu", color: Color(hex: "#d4a574"))
            }
            .padding(.vertical, 16)
        }
    }

    private func costStatCell(_ label: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(color)
            Text(value)
                .font(AppFont.mono(18, weight: .bold))
                .foregroundColor(colors.textPrimary)
            Text(label)
                .font(AppFont.mono(11))
                .foregroundColor(colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    var costByModelCard: some View {
        let byModel = tracker.tokensByModel(in: dateRange)
        let maxTok = byModel.first?.tokens ?? 1

        return StatSurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.textSecondary)
                    Text("Cost by Model")
                        .font(AppFont.mono(14, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                    Spacer()
                    Text("(estimated output cost)")
                        .font(AppFont.mono(11))
                        .foregroundColor(colors.textTertiary)
                }

                if byModel.isEmpty {
                    Text("No token data yet — start chatting to see cost estimates here.")
                        .font(AppFont.mono(12))
                        .foregroundColor(colors.textTertiary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 10) {
                        ForEach(byModel, id: \.modelId) { entry in
                            let tier = chatViewModel.availableModels.first { $0.id == entry.modelId }?.tier
                            let cost = ModelPricingStore.estimatedCost(tokens: entry.tokens, modelId: entry.modelId, tier: tier)
                            costModelRow(modelId: entry.modelId, tokens: entry.tokens, cost: cost, maxTokens: maxTok)
                        }
                    }
                }

                Text("Costs are approximate. Based on ~$0.005–$0.020 / 1K output tokens by tier.")
                    .font(AppFont.sans(10))
                    .foregroundColor(colors.textTertiary)
                    .padding(.top, 4)
            }
            .padding(14)
        }
    }

    private func costModelRow(modelId: String, tokens: Int, cost: Double, maxTokens: Int) -> some View {
        HStack(spacing: 10) {
            BrandLogoView(brand: ModelCatalog.brand(for: modelId), size: 16)
                .frame(width: 20)

            Text(ModelCatalog.displayName(modelId: modelId, apiName: nil))
                .font(AppFont.mono(13, weight: .medium))
                .foregroundColor(colors.textPrimary)
                .lineLimit(1)
                .frame(minWidth: 120, maxWidth: 180, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(colors.backgroundSubtle)
                    Capsule()
                        .fill(Color(hex: "#4dabf7").opacity(0.75))
                        .frame(width: max(6, geo.size.width * CGFloat(tokens) / CGFloat(max(maxTokens, 1))))
                }
            }
            .frame(height: 7)

            Text("\(tokens) tok")
                .font(AppFont.mono(11))
                .foregroundColor(colors.textSecondary)
                .frame(width: 72, alignment: .trailing)

            Text(ModelPricingStore.formatCost(cost))
                .font(AppFont.mono(11, weight: .semibold))
                .foregroundColor(Color(hex: "#6ee7a0"))
                .frame(width: 70, alignment: .trailing)
        }
    }

    var costByDayCard: some View {
        let byDay = tracker.tokensByDay(in: dateRange)

        return StatSurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.textSecondary)
                    Text("Token Usage Over Time")
                        .font(AppFont.mono(14, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                }

                TokenDayChartView(data: byDay)
                    .frame(height: 130)
            }
            .padding(14)
        }
    }
}

// MARK: - Shared surfaces

private struct StatSurfaceCard<Content: View>: View {
    @Environment(\.themeColors) private var colors
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(colors.backgroundElevated)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(colors.borderSubtle, lineWidth: 1)
            )
    }
}

// MARK: - Charts

private struct TPMLineChartView: View {
    @Environment(\.themeColors) private var colors
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let maxY: Double = 4
            let chartHeight = geo.size.height - 20
            let chartWidth = geo.size.width - 28

            ZStack(alignment: .bottomLeading) {
                // Grid
                ForEach(0..<5, id: \.self) { level in
                    let y = chartHeight - (CGFloat(level) / 4.0 * chartHeight)
                    Path { path in
                        path.move(to: CGPoint(x: 24, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(colors.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    Text("\(level)")
                        .font(AppFont.mono(9))
                        .foregroundColor(colors.textTertiary)
                        .position(x: 10, y: y)
                }

                // Line
                if values.count > 1 {
                    Path { path in
                        for (index, value) in values.enumerated() {
                            let x = 24 + (CGFloat(index) / CGFloat(values.count - 1)) * chartWidth
                            let normalized = min(value / maxY, 1.0)
                            let y = chartHeight - CGFloat(normalized) * chartHeight
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color(hex: "#4dabf7"), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                } else {
                    Path { path in
                        path.move(to: CGPoint(x: 24, y: chartHeight))
                        path.addLine(to: CGPoint(x: geo.size.width, y: chartHeight))
                    }
                    .stroke(Color(hex: "#4dabf7"), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        .background(colors.backgroundChart)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct UsageGridChartView: View {
    @Environment(\.themeColors) private var colors
    let data: [(date: Date, count: Int)]

    var body: some View {
        GeometryReader { geo in
            let maxY = 4
            let chartHeight = geo.size.height - 22
            let chartWidth = geo.size.width - 28
            let days = paddedDayRange()

            ZStack(alignment: .bottomLeading) {
                ForEach(0..<5, id: \.self) { level in
                    let y = chartHeight - (CGFloat(level) / 4.0 * chartHeight)
                    Path { path in
                        path.move(to: CGPoint(x: 24, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(colors.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    Text("\(level)")
                        .font(AppFont.mono(9))
                        .foregroundColor(colors.textTertiary)
                        .position(x: 10, y: y)
                }

                if days.isEmpty {
                    Path { path in
                        path.move(to: CGPoint(x: 24, y: chartHeight))
                        path.addLine(to: CGPoint(x: geo.size.width, y: chartHeight))
                    }
                    .stroke(Color(hex: "#4dabf7").opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                } else {
                    Path { path in
                        for (index, day) in days.enumerated() {
                            let count = data.first { Calendar.current.isDate($0.date, inSameDayAs: day) }?.count ?? 0
                            let x = 24 + (CGFloat(index) / CGFloat(max(days.count - 1, 1))) * chartWidth
                            let normalized = min(Double(count) / Double(maxY), 1.0)
                            let y = chartHeight - CGFloat(normalized) * chartHeight
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color(hex: "#4dabf7"), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        let x = 24 + (CGFloat(index) / CGFloat(max(days.count - 1, 1))) * chartWidth
                        Text(day.formatted(.dateTime.month(.abbreviated).day()))
                            .font(AppFont.mono(9))
                            .foregroundColor(colors.textTertiary)
                            .position(x: x, y: geo.size.height - 8)
                    }
                }
            }
        }
        .background(colors.backgroundChart)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func paddedDayRange() -> [Date] {
        if data.isEmpty {
            let calendar = Calendar.current
            let end = calendar.startOfDay(for: Date())
            return (0..<8).compactMap { calendar.date(byAdding: .day, value: -7 + $0, to: end) }
        }
        return data.map(\.date)
    }
}

private struct TokenDayChartView: View {
    @Environment(\.themeColors) private var colors
    let data: [(date: Date, tokens: Int)]

    var body: some View {
        GeometryReader { geo in
            let maxY = max(data.map(\.tokens).max() ?? 1, 1)
            let chartHeight = geo.size.height - 22
            let chartWidth  = geo.size.width  - 28
            let days = paddedDayRange()

            ZStack(alignment: .bottomLeading) {
                ForEach(0..<5, id: \.self) { level in
                    let y = chartHeight - (CGFloat(level) / 4.0 * chartHeight)
                    Path { path in
                        path.move(to: CGPoint(x: 24, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(colors.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }

                if days.count > 1 {
                    Path { path in
                        for (i, day) in days.enumerated() {
                            let tok = data.first { Calendar.current.isDate($0.date, inSameDayAs: day) }?.tokens ?? 0
                            let x = 24 + (CGFloat(i) / CGFloat(days.count - 1)) * chartWidth
                            let y = chartHeight - CGFloat(Double(tok) / Double(maxY)) * chartHeight
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else       { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(Color(hex: "#6ee7a0"), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                        let x = 24 + (CGFloat(i) / CGFloat(days.count - 1)) * chartWidth
                        Text(day.formatted(.dateTime.month(.abbreviated).day()))
                            .font(AppFont.mono(9))
                            .foregroundColor(colors.textTertiary)
                            .position(x: x, y: geo.size.height - 8)
                    }
                } else {
                    Path { path in
                        path.move(to: CGPoint(x: 24, y: chartHeight))
                        path.addLine(to: CGPoint(x: geo.size.width, y: chartHeight))
                    }
                    .stroke(Color(hex: "#6ee7a0").opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        .background(colors.backgroundChart)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func paddedDayRange() -> [Date] {
        if data.isEmpty {
            let cal = Calendar.current
            let end = cal.startOfDay(for: Date())
            return (0..<8).compactMap { cal.date(byAdding: .day, value: -7 + $0, to: end) }
        }
        return data.map(\.date)
    }
}
