import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: EchoNoteViewModel
    @State private var serverAddress = UserDefaults.standard.string(forKey: "serverAddress") ?? "ws://100.x.y.z:8765"
    @State private var token = ""
    @State private var showingToken = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Server address")
                        .font(.headline)
                    TextField("ws://Tailscale-IP:8765", text: $serverAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.isRecording)

                    Text("Session token")
                        .font(.headline)
                    HStack {
                        Group {
                            if showingToken {
                                TextField("Paste the server token", text: $token)
                            } else {
                                SecureField("Paste the server token", text: $token)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Button(showingToken ? "Hide" : "Show") { showingToken.toggle() }
                            .font(.caption)
                    }
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isRecording)
                    Text("The token is kept in this app’s Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                HStack(spacing: 12) {
                    Circle()
                        .fill(viewModel.isRecording ? .red : .gray)
                        .frame(width: 10, height: 10)
                    Text(viewModel.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.isRecording {
                        Text(viewModel.elapsedText)
                            .monospacedDigit()
                            .font(.subheadline.weight(.medium))
                    }
                }

                Button {
                    Task {
                        UserDefaults.standard.set(serverAddress, forKey: "serverAddress")
                        await viewModel.toggleRecording(address: serverAddress, token: token)
                    }
                } label: {
                    Label(viewModel.isRecording ? "Stop recording" : "Start recording",
                          systemImage: viewModel.isRecording ? "stop.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isRecording ? .red : .accentColor)
                .disabled(viewModel.isStarting || (!viewModel.isRecording && (serverAddress.isEmpty || token.count < 24)))

                HStack {
                    Text("Transcript")
                        .font(.title3.bold())
                    Spacer()
                    if !viewModel.transcript.isEmpty {
                        Button("Clear") { viewModel.clearTranscript() }
                            .font(.subheadline)
                    }
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if viewModel.transcript.isEmpty {
                                ContentUnavailableView("Nothing transcribed yet",
                                                      systemImage: "text.bubble",
                                                      description: Text("Start recording and recognized speech will appear here."))
                                    .frame(maxWidth: .infinity, minHeight: 180)
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
                    .onChange(of: viewModel.transcript.count) { _, _ in
                        if let last = viewModel.transcript.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("EchoNote")
            .task { token = KeychainToken.load() ?? "" }
            .onChange(of: token) { _, newValue in
                KeychainToken.save(newValue)
            }
        }
    }
}
