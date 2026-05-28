//
//  CalarmChatView.swift
//  Calarm
//
//  Conversational AI tab. Streams text from Apple Intelligence, supports
//  voice input via on-device speech recognition, and lets the model call
//  the app's tools (create/list/search/update/delete reminders).
//

import SwiftData
import SwiftUI

struct CalarmChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ReminderScheduler.self) private var reminderScheduler

    @State private var assistant: AssistantService?
    @State private var speech = SpeechRecognitionService()
    @State private var inputText: String = ""
    @State private var showingPermissionDeniedAlert = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let assistant {
                    chatBody(assistant)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Asistente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let assistant, !assistant.messages.isEmpty {
                        Button {
                            Haptics.light()
                            assistant.reset()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .accessibilityLabel("Nueva conversación")
                    }
                }
            }
            .onAppear {
                if assistant == nil {
                    assistant = AssistantService(
                        modelContainer: modelContext.container,
                        scheduler: reminderScheduler
                    )
                }
            }
            .alert("Permiso denegado", isPresented: $showingPermissionDeniedAlert) {
                Button("OK") { showingPermissionDeniedAlert = false }
            } message: {
                Text("Activa el micrófono y reconocimiento de voz en Ajustes → Calarm.")
            }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func chatBody(_ assistant: AssistantService) -> some View {
        if assistant.isAvailable == false {
            unavailableView(reason: assistant.unavailableReason ?? "")
        } else if assistant.messages.isEmpty {
            emptyStateAndInput(assistant)
        } else {
            messagesAndInput(assistant)
        }
    }

    // MARK: - Empty state with sample prompts

    private func emptyStateAndInput(_ assistant: AssistantService) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: DS.Spacing.xxl) {
                    Spacer(minLength: DS.Spacing.xxxl)
                    HeroIcon(systemName: "sparkles", tint: .appAccent)
                    VStack(spacing: DS.Spacing.sm) {
                        Text("¿En qué te ayudo?")
                            .font(.title2.bold())
                        Text("Crea, busca y modifica alarmas conversando. Todo en tu iPhone, sin internet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, DS.Spacing.xxl)
                    }
                    samplePrompts(assistant)
                    Spacer(minLength: DS.Spacing.xxl)
                }
            }
            inputBar(assistant)
        }
    }

    private func samplePrompts(_ assistant: AssistantService) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            samplePrompt(icon: "calendar",
                         text: appLocalized("¿Qué tengo hoy?"),
                         assistant: assistant)
            samplePrompt(icon: "birthday.cake.fill",
                         text: appLocalized("Cumple de mi mamá el 15 de marzo cada año"),
                         assistant: assistant)
            samplePrompt(icon: "magnifyingglass",
                         text: appLocalized("¿Cuántos cumpleaños hay este mes?"),
                         assistant: assistant)
            samplePrompt(icon: "bell.badge",
                         text: appLocalized("Pon una alarma mañana a las 8am para el pastillero"),
                         assistant: assistant)
        }
        .padding(.horizontal, DS.Spacing.lg)
    }

    private func samplePrompt(icon: String, text: String, assistant: AssistantService) -> some View {
        Button {
            Haptics.light()
            Task { await assistant.send(text) }
        } label: {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: DS.Spacing.sm)
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        }
        .buttonStyle(.pressable)
    }

    // MARK: - Messages list

    private func messagesAndInput(_ assistant: AssistantService) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: DS.Spacing.md) {
                        ForEach(assistant.messages) { message in
                            ChatBubbleView(message: message)
                                .id(message.id)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if assistant.isResponding,
                           assistant.messages.last?.content.isEmpty == true {
                            HStack {
                                TypingDots()
                                Spacer()
                            }
                            .padding(.horizontal, DS.Spacing.lg)
                        }
                    }
                    .padding(.vertical, DS.Spacing.md)
                    .animation(DS.Motion.smooth, value: assistant.messages.count)
                }
                .onChange(of: assistant.messages.last?.content) { _, _ in
                    if let last = assistant.messages.last {
                        withAnimation(DS.Motion.smooth) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            inputBar(assistant)
        }
    }

    // MARK: - Input bar

    private func inputBar(_ assistant: AssistantService) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: DS.Spacing.sm) {
                TextField(
                    "Mensaje",
                    text: speech.isRecording
                        ? Binding(get: { speech.transcription }, set: { _ in })
                        : $inputText,
                    axis: .vertical
                )
                .focused($inputFocused)
                .lineLimit(1...5)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .background(Color.dsFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .disabled(speech.isRecording)

                if inputText.isEmpty && !speech.isRecording {
                    micButton()
                } else if speech.isRecording {
                    stopMicButton()
                } else {
                    sendButton(assistant)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(Color(.systemBackground))
        }
    }

    private func micButton() -> some View {
        Button {
            Task { await startVoiceInput() }
        } label: {
            Image(systemName: "mic.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.appAccent))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hablar")
    }

    private func stopMicButton() -> some View {
        Button {
            stopVoiceInput()
        } label: {
            Image(systemName: "stop.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(.red))
                .symbolEffect(.pulse, options: .repeating)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Detener grabación")
    }

    private func sendButton(_ assistant: AssistantService) -> some View {
        Button {
            sendMessage(assistant)
        } label: {
            Image(systemName: "arrow.up")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.appAccent))
        }
        .buttonStyle(.plain)
        .disabled(assistant.isResponding || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .opacity(assistant.isResponding ? 0.5 : 1.0)
        .accessibilityLabel("Enviar")
    }

    // MARK: - Unavailable

    private func unavailableView(reason: String) -> some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()
            HeroIcon(systemName: "sparkles", tint: .secondary)
            VStack(spacing: DS.Spacing.sm) {
                Text("Apple Intelligence no disponible")
                    .font(.title3.bold())
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.xxl)
            }
            Spacer()
        }
    }

    // MARK: - Actions

    private func sendMessage(_ assistant: AssistantService) {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Haptics.light()
        inputText = ""
        inputFocused = false
        Task { await assistant.send(trimmed) }
    }

    private func startVoiceInput() async {
        let granted = await speech.requestAuthorization()
        guard granted else {
            showingPermissionDeniedAlert = true
            return
        }
        speech.refreshRecognizer()
        do {
            try speech.start()
            Haptics.light()
        } catch {
            speech.stop()
        }
    }

    private func stopVoiceInput() {
        speech.stop()
        // Transfer the transcription into the text field and let the user
        // review before sending.
        if !speech.transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputText = speech.transcription
            inputFocused = true
        }
        Haptics.light()
    }
}

// MARK: - Chat bubble

private struct ChatBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            if message.role == .user {
                Spacer(minLength: DS.Spacing.xxl)
                userBubble
            } else {
                assistantAvatar
                assistantBubble
                Spacer(minLength: DS.Spacing.xxl)
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
    }

    private var userBubble: some View {
        Text(message.content)
            .font(.body)
            .foregroundStyle(.white)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(Color.appAccent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .textSelection(.enabled)
    }

    private var assistantBubble: some View {
        Text(message.content)
            .font(.body)
            .foregroundStyle(.primary)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(Color.dsFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .textSelection(.enabled)
    }

    private var assistantAvatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.appAccent, Color.appAccent.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 30, height: 30)
            Image(systemName: "sparkles")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Typing dots indicator

private struct TypingDots: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(phase == i ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.15),
                        value: phase
                    )
            }
        }
        .padding(.leading, 40)
        .onAppear { phase = 2 }
    }
}
