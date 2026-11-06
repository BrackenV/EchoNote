import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var viewModel: EchoNoteViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingToken = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        connectionSettings
                            .id("top")
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
}
