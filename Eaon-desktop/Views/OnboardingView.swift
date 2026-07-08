import AppKit
import SwiftUI

/// Full-window gate shown whenever no API key is saved yet — a fresh
/// install, or any state where Keychain has nothing in it. There's no
/// separate "validate key" endpoint, so a successful `fetchModels()` call
/// doubles as the real check: it only succeeds if the key actually
/// authenticates, which is exactly what chatting would require anyway.
struct OnboardingView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var chatViewModel: ChatViewModel
    var onComplete: () -> Void

    @State private var apiKeyInput = ""
    @State private var isKeyVisible = false
    @State private var isVerifying = false
    @State private var didSucceed = false
    @State private var errorMessage: String?
    @State private var appeared = false
    @FocusState private var isFocused: Bool

    private var trimmedKey: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canContinue: Bool {
        !trimmedKey.isEmpty && !isVerifying && !didSucceed
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                VStack(spacing: 16) {
                    AquaMark(size: 52)

                    VStack(spacing: 8) {
                        Text("Welcome to Eaon")
                            .font(AppFont.mono(28, weight: .bold))
                            .foregroundStyle(colors.textPrimary)

                        Text("Enter your Aqua API key to start chatting.\nWe'll set up your models automatically.")
                            .font(AppFont.sans(14))
                            .foregroundStyle(colors.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(spacing: 12) {
                    keyField

                    if let errorMessage {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .padding(.top, 1)
                            Text(errorMessage)
                                .font(AppFont.sans(12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(colors.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    continueButton

                    Button {
                        NSWorkspace.shared.open(URL(string: "https://aquadevs.com")!)
                    } label: {
                        (Text("Don't have a key? ")
                            .foregroundStyle(colors.textSecondary)
                         + Text("Get one at aquadevs.com")
                            .foregroundStyle(colors.link))
                            .font(AppFont.mono(12.5))
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 360)
            }
            .scaleEffect(appeared ? 1 : 0.96)
            .opacity(appeared ? 1 : 0)

            Spacer()
            Spacer()

            Label("Stored securely in the macOS Keychain on this device only.", systemImage: "lock.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(colors.textTertiary)
                .padding(.bottom, 28)
                .opacity(appeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.backgroundPrimary)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) { appeared = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                AppFocus.activate()
                isFocused = true
            }
        }
        .onChange(of: apiKeyInput) { _, _ in
            if errorMessage != nil {
                withAnimation(.easeOut(duration: 0.15)) { errorMessage = nil }
            }
        }
    }

    // MARK: - Key field

    private var keyField: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 13))
                .foregroundStyle(colors.textTertiary)
                .frame(width: 16)

            Group {
                if isKeyVisible {
                    TextField("Paste your Aqua API key", text: $apiKeyInput)
                } else {
                    SecureField("Paste your Aqua API key", text: $apiKeyInput)
                }
            }
            .textFieldStyle(.plain)
            .font(AppFont.mono(14))
            .focused($isFocused)
            .disabled(isVerifying || didSucceed)
            .onSubmit { Task { await verify() } }

            if !trimmedKey.isEmpty {
                Button {
                    isKeyVisible.toggle()
                } label: {
                    Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                        .font(.system(size: 13))
                        .foregroundStyle(colors.textTertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(colors.backgroundInput)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isFocused ? colors.borderMedium : colors.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Continue button

    private var continueButton: some View {
        Button {
            Task { await verify() }
        } label: {
            HStack(spacing: 8) {
                if didSucceed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                    Text("You're all set")
                } else if isVerifying {
                    ProgressView()
                        .controlSize(.small)
                        .tint(colors.backgroundPrimary)
                    Text("Setting up your models…")
                } else {
                    Text("Continue")
                }
            }
            .font(AppFont.mono(14, weight: .semibold))
            .foregroundStyle(didSucceed ? .white : colors.backgroundPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(didSucceed ? Color.green.opacity(0.85) : colors.textPrimary.opacity(canContinue ? 1 : 0.35))
            )
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!canContinue)
        .animation(.easeOut(duration: 0.18), value: isVerifying)
        .animation(.easeOut(duration: 0.18), value: didSucceed)
    }

    // MARK: - Verify

    @MainActor
    private func verify() async {
        guard canContinue else { return }
        errorMessage = nil
        isVerifying = true

        do {
            try KeychainService.saveAPIKey(trimmedKey)
        } catch {
            errorMessage = error.localizedDescription
            isVerifying = false
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            return
        }

        await chatViewModel.fetchModels()

        if let modelsError = chatViewModel.modelsLoadError {
            // A key that doesn't authenticate is worse than no key at all —
            // don't leave it sitting in Keychain looking "saved" when it
            // doesn't actually work.
            KeychainService.deleteAPIKey()
            errorMessage = "We couldn't verify that key: \(modelsError)"
            isVerifying = false
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            return
        }

        isVerifying = false
        didSucceed = true
        try? await Task.sleep(nanoseconds: 550_000_000)
        onComplete()
    }
}
