import AVFoundation
import Combine
import Foundation

struct TranscriptSegment: Identifiable {
    let id: Int
    let text: String
}

@MainActor
final class EchoNoteViewModel: ObservableObject {
    @Published private(set) var status = "Ready"
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var transcript: [TranscriptSegment] = []
    @Published private(set) var elapsedText = "00:00"

    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var transport: EchoNoteTransport?
    private var sessionID = ""
    private var startTime: Date?
    private var timer: Timer?
    private var lastSegmentIndex = -1
    private var eventTask: Task<Void, Never>?

    func toggleRecording(address: String, token: String) async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording(address: address, token: token)
        }
    }

    func clearTranscript() { transcript.removeAll() }

    private func startRecording(address: String, token: String) async {
        guard let url = URL(string: address), ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            status = "Enter a valid ws:// or wss:// server address."
            return
        }
        guard token.count >= 24 else {
            status = "The server token must be at least 24 characters."
            return
        }
        isStarting = true
        status = "Connecting to server…"
        do {
            try await requestMicrophonePermission()
            sessionID = UUID().uuidString
            lastSegmentIndex = -1
            let client = EchoNoteTransport()
            transport = client
            try await client.connect(url: url, token: token, sessionID: sessionID)
            eventTask = Task { [weak self, client] in
                for await event in client.events {
                    guard let self else { return }
                    self.handle(event)
                }
            }
            try startAudioCapture(transport: client)
            isRecording = true
            startTime = Date()
            status = "Recording · connected"
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateElapsed() }
            }
        } catch {
            await transport?.disconnect()
            transport = nil
            status = error.localizedDescription
        }
        isStarting = false
    }

    private func requestMicrophonePermission() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw ClientError.microphoneDenied }
    }

    private func startAudioCapture(transport: EchoNoteTransport) throws {
        let input = audioEngine.inputNode
        let sourceFormat = input.inputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16_000,
                                               channels: 1,
                                               interleaved: true),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw ClientError.audioFormatUnavailable
        }
        self.converter = converter
        try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.allowBluetooth])
        try AVAudioSession.sharedInstance().setActive(true)
        input.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer, using: converter) else { return }
            Task {
                do { try await transport.enqueueAudio(converted) }
                catch { await MainActor.run { self.captureFailed(error) } }
            }
        }
        audioEngine.prepare()
        do { try audioEngine.start() }
        catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private nonisolated func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) -> Data? {
        let ratio = 16_000 / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: max(capacity, 1)) else { return nil }
        var suppliedInput = false
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil, result != .error,
              let audioBuffer = output.audioBufferList.pointee.mBuffers.mData,
              output.audioBufferList.pointee.mBuffers.mDataByteSize > 0 else { return nil }
        return Data(bytes: audioBuffer, count: Int(output.audioBufferList.pointee.mBuffers.mDataByteSize))
    }

    private func stopRecording() async {
        guard isRecording else { return }
        status = "Finishing transcription…"
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRecording = false
        timer?.invalidate()
        timer = nil
        do { try await transport?.finish(sessionID: sessionID) }
        catch { status = "Stopped · \(error.localizedDescription)" }
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .transcript(let index, let text):
            guard index > lastSegmentIndex else { return }
            lastSegmentIndex = index
            transcript.append(TranscriptSegment(id: index, text: text))
        case .final(let failed):
            status = failed.isEmpty ? "Finished" : "Finished with \(failed.count) segment error(s)."
            transport = nil
            eventTask = nil
        case .error(let message):
            status = "Server error: \(message)"
        }
    }

    private func captureFailed(_ error: Error) {
        status = "Audio send failed: \(error.localizedDescription)"
        if isRecording { Task { await stopRecording() } }
    }

    private func updateElapsed() {
        guard let startTime else { return }
        let seconds = max(0, Int(Date().timeIntervalSince(startTime)))
        elapsedText = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

enum ClientError: LocalizedError {
    case microphoneDenied
    case audioFormatUnavailable
    case server(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Microphone access is off. Allow it in Settings to record."
        case .audioFormatUnavailable: return "Could not prepare the microphone audio format."
        case .server(let message): return message
        }
    }
}
