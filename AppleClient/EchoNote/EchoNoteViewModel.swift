import AVFoundation
import Combine
import Foundation

private struct AudioCaptureOutput: Sendable {
    let pcmChunks: [Data]
    let endsSegment: Bool
    let keepAlive: Bool
}

private final class VoiceActivityGate: @unchecked Sendable {
    private let lock = NSLock()
    private let bytesPerSecond = 16_000 * 2
    private let speechThreshold = 0.012
    private let endSilenceSeconds = 0.75
    private let preRollSeconds = 0.25
    private let trailingAudioSeconds = 0.15
    private var isSpeaking = false
    private var preRoll: [Data] = []
    private var preRollBytes = 0
    private var candidateSpeechSeconds = 0.0
    private var trailingSilence: [Data] = []
    private var trailingSilenceBytes = 0
    private var lastActivityTime = Date.timeIntervalSinceReferenceDate

    func process(_ pcm: Data) -> AudioCaptureOutput {
        lock.lock()
        defer { lock.unlock() }
        let duration = Double(pcm.count) / Double(bytesPerSecond)
        let isVoiced = rms(of: pcm) >= speechThreshold

        if isSpeaking {
            if isVoiced {
                let chunks = trailingSilence + [pcm]
                trailingSilence.removeAll(keepingCapacity: true)
                trailingSilenceBytes = 0
                lastActivityTime = Date.timeIntervalSinceReferenceDate
                return AudioCaptureOutput(pcmChunks: chunks, endsSegment: false, keepAlive: false)
            }
            trailingSilence.append(pcm)
            trailingSilenceBytes += pcm.count
            let silenceDuration = Double(trailingSilenceBytes) / Double(bytesPerSecond)
            guard silenceDuration >= endSilenceSeconds else {
                return AudioCaptureOutput(pcmChunks: [], endsSegment: false, keepAlive: false)
            }
            let tailBytes = Int(Double(bytesPerSecond) * trailingAudioSeconds)
            let tail = Self.prefix(tailBytes, from: trailingSilence)
            isSpeaking = false
            trailingSilence.removeAll(keepingCapacity: true)
            trailingSilenceBytes = 0
            preRoll.removeAll(keepingCapacity: true)
            preRollBytes = 0
            candidateSpeechSeconds = 0
            lastActivityTime = Date.timeIntervalSinceReferenceDate
            return AudioCaptureOutput(pcmChunks: tail.isEmpty ? [] : [tail], endsSegment: true, keepAlive: false)
        }

        appendToPreRoll(pcm)
        if isVoiced {
            candidateSpeechSeconds += duration
            if candidateSpeechSeconds >= 0.06 {
                isSpeaking = true
                candidateSpeechSeconds = 0
                lastActivityTime = Date.timeIntervalSinceReferenceDate
                let chunks = preRoll
                preRoll.removeAll(keepingCapacity: true)
                preRollBytes = 0
                return AudioCaptureOutput(pcmChunks: chunks, endsSegment: false, keepAlive: false)
            }
        } else {
            candidateSpeechSeconds = 0
        }

        let now = Date.timeIntervalSinceReferenceDate
        if now - lastActivityTime >= 5 {
            lastActivityTime = now
            return AudioCaptureOutput(pcmChunks: [], endsSegment: false, keepAlive: true)
        }
        return AudioCaptureOutput(pcmChunks: [], endsSegment: false, keepAlive: false)
    }

    func finish() -> AudioCaptureOutput {
        lock.lock()
        defer { lock.unlock() }
        guard isSpeaking else { return AudioCaptureOutput(pcmChunks: [], endsSegment: false, keepAlive: false) }
        let tailBytes = Int(Double(bytesPerSecond) * trailingAudioSeconds)
        let tail = Self.prefix(tailBytes, from: trailingSilence)
        isSpeaking = false
        trailingSilence.removeAll(keepingCapacity: true)
        trailingSilenceBytes = 0
        return AudioCaptureOutput(pcmChunks: tail.isEmpty ? [] : [tail], endsSegment: true, keepAlive: false)
    }

    private func appendToPreRoll(_ pcm: Data) {
        let maximumBytes = Int(Double(bytesPerSecond) * preRollSeconds)
        preRoll.append(pcm)
        preRollBytes += pcm.count
        while preRollBytes > maximumBytes, !preRoll.isEmpty {
            preRollBytes -= preRoll.removeFirst().count
        }
    }

    private func rms(of data: Data) -> Double {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        var sumSquares = 0.0
        data.withUnsafeBytes { rawBuffer in
            for byteOffset in stride(from: 0, to: sampleCount * 2, by: 2) {
                let rawSample = rawBuffer.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self)
                let sample = Double(Int16(littleEndian: rawSample)) / 32_768.0
                sumSquares += sample * sample
            }
        }
        return sqrt(sumSquares / Double(sampleCount))
    }

    private static func prefix(_ byteCount: Int, from chunks: [Data]) -> Data {
        var result = Data()
        for chunk in chunks {
            let remaining = byteCount - result.count
            guard remaining > 0 else { break }
            result.append(chunk.prefix(remaining))
        }
        return result
    }
}

enum EchoNoteConnectionState: Equatable {
    case checking
    case connected
    case unavailable(String)
}

@MainActor
final class EchoNoteViewModel: ObservableObject {
    @Published private(set) var status = "Ready"
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var connectionState: EchoNoteConnectionState = .checking
    @Published private(set) var transcript = ""
    @Published private(set) var elapsedText = "00:00"
    @Published var voiceActivityEnabled = UserDefaults.standard.object(forKey: "echoNote.voiceActivityEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(voiceActivityEnabled, forKey: "echoNote.voiceActivityEnabled") }
    }
    @Published var segmentSeconds = UserDefaults.standard.object(forKey: "echoNote.segmentSeconds") as? Int ?? 10 {
        didSet { UserDefaults.standard.set(segmentSeconds, forKey: "echoNote.segmentSeconds") }
    }

    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var transport: EchoNoteTransport?
    private var sessionID = ""
    private var startTime: Date?
    private var timer: Timer?
    private var lastSegmentIndex = -1
    private var eventTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var captureContinuation: AsyncStream<AudioCaptureOutput>.Continuation?
    private var captureSenderTask: Task<Void, Never>?
    private var voiceActivityGate: VoiceActivityGate?

    var connectionSummary: String {
        switch connectionState {
        case .checking:
            return "Checking PC on Tailscale…"
        case .connected:
            return "PC connected · Ready"
        case .unavailable(let message):
            return message
        }
    }

    func checkServer() {
        healthTask?.cancel()
        connectionState = .checking
        healthTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await EchoNoteHealthCheck.check(url: EchoNoteConfiguration.serverURL)
                    guard !Task.isCancelled else { return }
                    self.connectionState = .connected
                } catch let error as ClientError {
                    guard !Task.isCancelled else { return }
                    self.connectionState = .unavailable(error.localizedDescription)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.connectionState = .unavailable("PC unreachable on Tailscale. Check that EchoNote server is running.")
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func clearTranscript() { transcript = "" }

    func refreshElapsedTime() {
        guard isRecording else { return }
        updateElapsed()
    }

    private func startRecording() async {
        isStarting = true
        status = "Connecting to server…"
        do {
            try await requestMicrophonePermission()
            sessionID = UUID().uuidString
            lastSegmentIndex = -1
            let vadEnabled = voiceActivityEnabled
            let segmentLength = vadEnabled ? 10 : segmentSeconds
            let client = EchoNoteTransport()
            transport = client
            try await client.connect(
                url: EchoNoteConfiguration.serverURL,
                sessionID: sessionID,
                segmentSeconds: segmentLength,
                voiceActivityEnabled: vadEnabled
            )
            eventTask = Task { [weak self, client] in
                for await event in client.events {
                    guard let self else { return }
                    self.handle(event)
                }
            }
            try startAudioCapture(transport: client, voiceActivityEnabled: vadEnabled)
            isRecording = true
            startTime = Date()
            status = "Recording · connected"
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateElapsed() }
            }
        } catch {
            captureContinuation?.finish()
            captureSenderTask?.cancel()
            captureContinuation = nil
            captureSenderTask = nil
            voiceActivityGate = nil
            await transport?.disconnect()
            transport = nil
            connectionState = .unavailable("Start failed: \(error.localizedDescription)")
        }
        isStarting = false
    }

    private func requestMicrophonePermission() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw ClientError.microphoneDenied }
    }

    private func startAudioCapture(transport: EchoNoteTransport, voiceActivityEnabled: Bool) throws {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true)
        } catch {
            throw ClientError.audioSessionActivationFailed
        }

        let input = audioEngine.inputNode
        let sourceFormat = input.inputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16_000,
                                               channels: 1,
                                               interleaved: true),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            try? audioSession.setActive(false)
            throw ClientError.audioFormatUnavailable
        }
        self.converter = converter
        let gate = voiceActivityEnabled ? VoiceActivityGate() : nil
        voiceActivityGate = gate
        var continuation: AsyncStream<AudioCaptureOutput>.Continuation!
        let stream = AsyncStream<AudioCaptureOutput>(bufferingPolicy: .bufferingOldest(128)) {
            continuation = $0
        }
        captureContinuation = continuation
        let currentSessionID = sessionID
        captureSenderTask = Task { [weak self, transport] in
            for await output in stream {
                do {
                    for pcm in output.pcmChunks { try await transport.enqueueAudio(pcm) }
                    if output.endsSegment { try await transport.endSegment(sessionID: currentSessionID) }
                    if output.keepAlive { try await transport.keepAlive(sessionID: currentSessionID) }
                } catch {
                    await MainActor.run {
                        self?.captureContinuation?.finish()
                        self?.captureFailed(error)
                    }
                    return
                }
            }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer, using: converter) else { return }
            let output = gate?.process(converted) ?? AudioCaptureOutput(
                pcmChunks: [converted], endsSegment: false, keepAlive: false
            )
            guard !output.pcmChunks.isEmpty || output.endsSegment || output.keepAlive else { return }
            if case .dropped = continuation.yield(output) {
                Task { @MainActor in self.captureFailed(ClientError.audioQueueOverflow) }
            }
        }
        audioEngine.prepare()
        do { try audioEngine.start() }
        catch {
            input.removeTap(onBus: 0)
            captureContinuation?.finish()
            captureSenderTask?.cancel()
            captureContinuation = nil
            captureSenderTask = nil
            voiceActivityGate = nil
            try? audioSession.setActive(false)
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
        if let finalOutput = voiceActivityGate?.finish(),
           !finalOutput.pcmChunks.isEmpty || finalOutput.endsSegment {
            _ = captureContinuation?.yield(finalOutput)
        }
        captureContinuation?.finish()
        await captureSenderTask?.value
        captureContinuation = nil
        captureSenderTask = nil
        voiceActivityGate = nil
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
            let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return }
            if !transcript.isEmpty { transcript += " " }
            transcript += sentence
        case .final(let failed):
            status = failed.isEmpty ? "Finished" : "Finished with \(failed.count) segment error(s)."
            transport = nil
            eventTask = nil
        case .error(let message):
            status = "Server error: \(message)"
        case .disconnected(let message):
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            isRecording = false
            timer?.invalidate()
            timer = nil
            captureContinuation?.finish()
            captureContinuation = nil
            captureSenderTask = nil
            voiceActivityGate = nil
            try? AVAudioSession.sharedInstance().setActive(false)
            transport = nil
            eventTask = nil
            status = "Disconnected: \(message) Start a new recording to reconnect."
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
    case audioSessionActivationFailed
    case audioQueueOverflow
    case server(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Microphone access is off. Allow it in Settings to record."
        case .audioFormatUnavailable: return "Could not prepare the microphone audio format."
        case .audioSessionActivationFailed:
            return "iOS couldn't activate the microphone. A Discord or phone call may be using it; leave the call, then try again."
        case .audioQueueOverflow:
            return "Audio processing fell behind. Stop and start a new recording."
        case .server(let message): return message
        }
    }
}
