import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var viewModel: EchoNoteViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var spherePulse = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        recordingSphere
                            .id("top")
                        connectionStatus
                        audioSettings
                        transcriptHeader

                        Group {
                            if viewModel.transcript.isEmpty {
                                Text("Start recording and recognized speech will appear here.")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(viewModel.transcript)
                                    .textSelection(.enabled)
                            }
                        }
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding()
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
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                spherePulse = true
            }
        }
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
        .padding(.top, 14)
    }

    private var connectionStatus: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(viewModel.isRecording ? .red : (viewModel.isStarting ? .orange : connectionColor))
                .frame(width: 11, height: 11)
            Text(viewModel.isRecording || viewModel.isStarting ? viewModel.status : viewModel.connectionSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            if viewModel.isRecording {
                Text(viewModel.elapsedText)
                    .monospacedDigit()
                    .font(.subheadline.weight(.medium))
            }
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .combine)
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
            Text("Transcript")
                .font(.title3.bold())
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

    private var connectionColor: Color {
        switch viewModel.connectionState {
        case .connected:
            return .green
        case .checking:
            return .orange
        case .unavailable:
            return .red
        }
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
}
