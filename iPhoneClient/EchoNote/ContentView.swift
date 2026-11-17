import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var viewModel: EchoNoteViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var spherePulse = false
    @State private var transcriptExpanded = true
    @State private var transcriptVisible = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
                        recordingSphere
                            .id("top")
                        recordingStatus
                        audioSettings
                        transcriptHeader

                        if transcriptExpanded {
                            Group {
                                if viewModel.transcript.isEmpty {
                                    Text("Start recording and recognized speech will appear here.")
                                        .foregroundStyle(.white.opacity(0.55))
                                } else {
                                    Text(viewModel.transcript)
                                        .foregroundStyle(.white)
                                        .textSelection(.enabled)
                                        .opacity(transcriptVisible ? 1 : 0)
                                        .onAppear {
                                            withAnimation(.easeIn(duration: 0.65)) { transcriptVisible = true }
                                        }
                                        .animation(.easeIn(duration: 0.65), value: transcriptVisible)
                                        .transition(.opacity)
                                }
                            }
                            .font(.body)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .animation(.easeInOut(duration: 0.25), value: transcriptExpanded)
                        }
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 22)
                    .padding(.top, 24)
                    .padding(.bottom, 22)
                }
                .scrollIndicators(.visible)
                .scrollBounceBehavior(.always)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.easeInOut) { proxy.scrollTo("top", anchor: .top) }
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .accessibilityLabel("Scroll to top")
                    }
                }
            }
            .navigationTitle("EchoNote")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            viewModel.checkServer()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewModel.refreshElapsedTime() }
        }
        .onChange(of: viewModel.transcript.isEmpty) { _, isEmpty in
            if isEmpty { transcriptVisible = false }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                spherePulse = true
            }
        }
        .overlay(alignment: .top) {
            if let error = bannerError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 1))
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: bannerError)
    }

    private var recordingSphere: some View {
        Button {
            Task { await viewModel.toggleRecording() }
        } label: {
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [.white.opacity(0.72), sphereColor.opacity(0.94), sphereColor],
                        center: .init(x: 0.32, y: 0.25),
                        startRadius: 4,
                        endRadius: 142
                    ))
                Circle()
                    .strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
                    .padding(7)
                Image(systemName: sphereSymbol)
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 168, height: 168)
            .shadow(color: sphereColor.opacity(0.55), radius: spherePulse ? 28 : 14, y: 7)
            .scaleEffect(spherePulse ? 1.035 : 1)
            .animation(.easeInOut(duration: 1.1), value: spherePulse)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isStarting || (!viewModel.isRecording && !isServerReady))
        .accessibilityLabel(sphereAccessibilityLabel)
        .accessibilityHint(viewModel.isRecording ? "Stops the current recording" : "Starts a recording")
        .padding(.top, 30)
    }

    @ViewBuilder
    private var recordingStatus: some View {
        if viewModel.isRecording {
            HStack {
                Text("Recording")
                Spacer()
                Text(viewModel.elapsedText)
                    .monospacedDigit()
                    .fontWeight(.medium)
            }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        } else if viewModel.isStarting {
            Text(viewModel.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var audioSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $viewModel.voiceActivityEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Voice activity detection")
                        .font(.headline)
                    Text("Send speech and split after pauses")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(viewModel.isRecording || viewModel.isStarting)

            if !viewModel.voiceActivityEnabled {
                Picker("Chunk length", selection: $viewModel.segmentSeconds) {
                    ForEach([5, 10, 15, 30], id: \.self) { seconds in
                        Text("\(seconds) sec").tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                .disabled(viewModel.isRecording || viewModel.isStarting)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var transcriptHeader: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { transcriptExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Text("Transcript")
                        .font(.title3.bold())
                    Image(systemName: transcriptExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityHint(transcriptExpanded ? "Hides the transcript" : "Shows the transcript")
            if !viewModel.transcript.isEmpty {
                Button {
                    UIPasteboard.general.string = viewModel.transcript
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .font(.subheadline)
                .accessibilityLabel("Copy transcript")
                Button("Clear") { viewModel.clearTranscript() }
                    .font(.subheadline)
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    private var isServerReady: Bool {
        if case .connected = viewModel.connectionState { return true }
        return false
    }

    private var sphereColor: Color {
        if viewModel.isRecording { return .red }
        switch viewModel.connectionState {
        case .connected: return .green
        case .checking: return .orange
        case .unavailable: return .red
        }
    }

    private var sphereSymbol: String {
        if viewModel.isStarting { return "ellipsis" }
        if viewModel.isRecording { return "stop.fill" }
        if case .unavailable = viewModel.connectionState { return "exclamationmark" }
        if case .checking = viewModel.connectionState { return "ellipsis" }
        return "record.circle.fill"
    }

    private var sphereAccessibilityLabel: String {
        if viewModel.isStarting { return "Connecting to server" }
        if viewModel.isRecording { return "Stop recording" }
        if case .unavailable = viewModel.connectionState { return "Server unavailable" }
        if case .checking = viewModel.connectionState { return "Checking server" }
        return "Start recording"
    }

    private var bannerError: String? {
        if case .unavailable(let message) = viewModel.connectionState { return message }
        for prefix in ["Server error:", "Audio send failed:", "Disconnected:", "Stopped ·"] {
            if viewModel.status.hasPrefix(prefix) { return viewModel.status }
        }
        return nil
    }
}
