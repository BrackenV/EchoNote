import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: EchoNoteViewModel
    @State private var showingToken = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        connectionSettings
                        connectionStatus

                        Button {
                            Task { await viewModel.toggleRecording() }
                        } label: {
                            Label(viewModel.isRecording ? "Stop recording" : "Start recording",
                                  systemImage: viewModel.isRecording ? "stop.fill" : "mic.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(viewModel.isRecording ? .red : .accentColor)
                        .disabled(viewModel.isStarting || viewModel.connectionState != .connected)

                        transcriptHeader

                        LazyVStack(alignment: .leading, spacing: 10) {
                            if viewModel.transcript.isEmpty {
                                Text("Start recording and recognized speech will appear here.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            } else {
                                ForEach(viewModel.transcript) { segment in
                                    Text(segment.text.isEmpty ? "(No speech recognized in this segment.)" : segment.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                                        .id(segment.id)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .scrollIndicators(.visible)
                .scrollBounceBehavior(.always)
                .onChange(of: viewModel.transcript.count) { _, _ in
                    if let last = viewModel.transcript.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .navigationTitle("EchoNote")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            viewModel.checkServer()
        }
    }

    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.secondary)
                Text("PC server")
                    .font(.headline)
                Spacer()
                Text("TAILSCALE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(EchoNoteConfiguration.serverAddress)
                .font(.system(.subheadline, design: .monospaced))
                .textSelection(.enabled)

        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
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

    private var transcriptHeader: some View {
        HStack {
            Text("Transcript")
                .font(.title3.bold())
            Spacer()
            if !viewModel.transcript.isEmpty {
                Button("Clear") { viewModel.clearTranscript() }
                    .font(.subheadline)
            }
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
}
