import AppKit
import AVFoundation
import IOKit.pwr_mgt

final class EchoStream {
    private let queue = DispatchQueue(label: "echonote.stream")
    private let socket: URLSessionWebSocketTask
    private let sessionID = UUID().uuidString
    private var samples: [Int16] = []
    private var sourceRate: Double = 0
    private var stridePhase = 0.0
    var onText: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    init(url: URL) { var request = URLRequest(url: url); request.timeoutInterval = 8; socket = URLSession.shared.webSocketTask(with: request) }

    func connect(completion: @escaping (String?) -> Void) {
        socket.resume()
        let json: [String: Any] = ["type":"start", "protocol_version":1, "session_id":sessionID,
                                   "sample_rate":16000, "channels":1, "sample_format":"s16le",
                                   "segment_seconds":10, "vad_enabled":false]
        guard let data = try? JSONSerialization.data(withJSONObject: json), let body = String(data: data, encoding: .utf8) else { completion("Could not prepare EchoNote connection."); return }
        socket.send(.string(body)) { [weak self] error in
            guard let self else { return }
            if let error { completion(error.localizedDescription); return }
            self.socket.receive { result in
                switch result {
                case .failure(let error): completion(error.localizedDescription)
                case .success(.string(let text)):
                    guard let data = text.data(using: .utf8), let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], reply["type"] as? String == "started", reply["session_id"] as? String == self.sessionID else { completion("EchoNote rejected the recording session."); return }
                    completion(nil); self.receiveLoop()
                case .success: completion("EchoNote sent an invalid start response.")
                }
            }
        }
    }

    func append(_ input: [Float], rate: Double) {
        queue.async {
            guard rate > 0 else { return }
            if self.sourceRate != rate { self.sourceRate = rate; self.stridePhase = 0 }
            let step = rate / 16000.0
            for sample in input {
                self.stridePhase += 1
                if self.stridePhase >= step {
                    self.stridePhase -= step
                    let clipped = max(-1, min(1, sample.isFinite ? sample : 0))
                    self.samples.append(Int16((clipped * 32767).rounded()))
                }
            }
            while self.samples.count >= 6400 {
                let frame = self.samples.prefix(6400).flatMap { $0.littleEndianBytes }
                self.samples.removeFirst(6400)
                self.socket.send(.data(Data(frame))) { error in if let error { DispatchQueue.main.async { self.onStatus?("Transcription connection lost: \(error.localizedDescription)") } } }
            }
        }
    }

    func finish() {
        queue.async {
            if !self.samples.isEmpty {
                let frame = self.samples.flatMap { $0.littleEndianBytes }; self.samples.removeAll()
                self.socket.send(.data(Data(frame))) { _ in
                    let body = try? JSONSerialization.data(withJSONObject: ["type":"stop", "session_id":self.sessionID])
                    guard let body, let text = String(data: body, encoding: .utf8) else { return }
                    self.socket.send(.string(text)) { _ in }
                }
            } else {
                let body = try? JSONSerialization.data(withJSONObject: ["type":"stop", "session_id":self.sessionID])
                if let body, let text = String(data: body, encoding: .utf8) { self.socket.send(.string(text)) { _ in } }
            }
        }
    }

    private func receiveLoop() {
        socket.receive { [weak self] result in
            guard let self else { return }
            if case .success(.string(let text)) = result, let data = text.data(using: .utf8), let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if message["type"] as? String == "transcript_segment", let phrase = message["text"] as? String, !phrase.isEmpty { DispatchQueue.main.async { self.onText?(phrase) } }
                if message["type"] as? String == "error", let error = message["message"] as? String { DispatchQueue.main.async { self.onStatus?("Transcription: \(error)") } }
                if message["type"] as? String == "final" { DispatchQueue.main.async { self.onStatus?("Transcription finished") }; return }
                self.receiveLoop()
            } else if case .failure(let error) = result { DispatchQueue.main.async { self.onStatus?("Transcription connection lost: \(error.localizedDescription)") } }
        }
    }
}

private extension Int16 { var littleEndianBytes: [UInt8] { let value = UInt16(bitPattern: littleEndian); return [UInt8(value & 0xff), UInt8(value >> 8)] } }

final class Capture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "lecture.capture", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var writer: UnsafeMutableRawPointer?
    private var destination: URL?
    private var active = false
    private var lastMeter = Date.distantPast
    var onLevel: ((Double) -> Void)?
    var onPCM: (([Float], Double) -> Void)?
    var onFailure: ((String) -> Void)?
    func start(device: AVCaptureDevice, url: URL, completion: @escaping (String?) -> Void) {
        queue.async {
            do {
                let s = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: device)
                guard s.canAddInput(input) else { throw NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "This microphone cannot be opened."]) }
                s.addInput(input)
                let output = AVCaptureAudioDataOutput()
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
                output.audioSettings = settings
                guard s.canAddOutput(output) else { throw NSError(domain: "Recorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audio capture is unavailable."]) }
                s.addOutput(output)
                output.setSampleBufferDelegate(self, queue: self.queue)
                self.destination = url
                self.active = true
                self.session = s
                s.startRunning()
                guard s.isRunning else { self.active = false; throw NSError(domain: "Recorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "The microphone did not start."]) }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                self.active = false
                self.session = nil
                DispatchQueue.main.async { completion(error.localizedDescription) }
            }
        }
    }
    func stop(completion: @escaping (Bool, Bool) -> Void) {
        queue.async {
            self.active = false
            self.session?.stopRunning()
            self.session = nil
            let hadAudio = self.writer != nil
            let success = self.writer.map { lr_close($0) == 0 } ?? false
            self.writer = nil
            DispatchQueue.main.async { completion(success, hadAudio) }
        }
    }
    private func fail(_ message: String) {
        guard active else { return }
        active = false
        DispatchQueue.main.async { self.onFailure?(message) }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard active else { return }
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer), let format = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { fail("The microphone returned an unknown format."); return }
        let f = format.pointee
        guard f.mFormatID == kAudioFormatLinearPCM, f.mBitsPerChannel == 32, f.mChannelsPerFrame == 1, f.mFormatFlags & kAudioFormatFlagIsFloat != 0, f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { fail("The microphone could not supply mono PCM audio."); return }
        if writer == nil {
            guard let url = destination else { return }
            writer = url.path.withCString { lr_open($0, UInt32(f.mSampleRate)) }
            guard writer != nil else { fail("Could not create the recording. Check the save folder and available disk space."); return }
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { fail("The microphone returned an empty audio buffer."); return }
        var pointer: UnsafeMutablePointer<Int8>?
        var length = 0
        var contiguous = 0
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguous, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr, contiguous == length, let pointer = pointer else { fail("Unable to read the microphone audio buffer."); return }
        let result = pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { lr_write(writer, $0, length / 4) }
        if let onPCM {
            let samples = Array(UnsafeBufferPointer(start: pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { $0 }, count: length / 4))
            onPCM(samples, f.mSampleRate)
        }
        if result != 0 { fail("Writing audio failed. The recording has stopped; check available disk space."); return }
        let rms = Double(lr_level(writer))
        let meter = rms > 0 ? max(0, min(1, (20 * log10(rms) + 60) / 60)) : 0
        if Date().timeIntervalSince(lastMeter) >= 1.0 / 30.0 {
            lastMeter = Date()
            DispatchQueue.main.async { self.onLevel?(meter) }
        }
    }
}

final class SmoothMeterView: NSView {
    private var targetLevel: CGFloat = 0
    private var displayedLevel: CGFloat = 0
    private var lastFrameTime = ProcessInfo.processInfo.systemUptime

    func setTarget(_ value: Double) {
        targetLevel = CGFloat(max(0, min(1, value)))
    }

    func reset() {
        targetLevel = 0
        displayedLevel = 0
        needsDisplay = true
    }

    func animateFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = min(now - lastFrameTime, 0.1)
        lastFrameTime = now
        let timeConstant = targetLevel > displayedLevel ? 0.07 : 0.20
        let easing = CGFloat(1 - exp(-delta / timeConstant))
        displayedLevel += (targetLevel - displayedLevel) * easing
        if abs(targetLevel - displayedLevel) < 0.001 { displayedLevel = targetLevel }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.24).setFill()
        track.fill()
        guard displayedLevel > 0 else { return }
        let filled = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width * displayedLevel, height: bounds.height)
        let bar = NSBezierPath(roundedRect: filled, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.systemGreen.setFill()
        bar.fill()
    }
}

final class RecordingDotView: NSView {
    var isRecording = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = min(bounds.width, bounds.height)
        let dot = NSBezierPath(ovalIn: NSRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter))
        (isRecording ? NSColor.systemRed : NSColor.systemGray).setFill()
        dot.fill()
    }
}

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let microphone = NSButton(title: "Select microphone", target: nil, action: nil)
    let record = NSButton(title: "Record", target: nil, action: nil)
    let newLecture = NSButton(title: "New lecture", target: nil, action: nil)
    let reveal = NSButton(title: "Open folder", target: nil, action: nil)
    let transcriptionToggle = NSButton(checkboxWithTitle: "Send audio to PC for transcription", target: nil, action: nil)
    let transcriptButton = NSButton(title: "Transcript window", target: nil, action: nil)
    let elapsed = NSTextField(labelWithString: "00:00:00")
    let destinationLabel = NSTextField(labelWithString: "Ready")
    let status = NSTextField(wrappingLabelWithString: "")
    let recordingDot = RecordingDotView(frame: .zero)
    let meter = SmoothMeterView(frame: .zero)
    let capture = Capture()
    var devices: [AVCaptureDevice] = []
    var selectedMicrophoneID: String?
    var folder = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Lecture_Modules", isDirectory: true).appendingPathComponent("CS4100 Fundamentals of Business Systems Design", isDirectory: true).appendingPathComponent("Week 4", isDirectory: true)
    var selectedModule: String? = "CS4100 Fundamentals of Business Systems Design"
    var selectedWeek: Int? = 4
    weak var lectureWeekCombo: NSComboBox?
    var elapsedBase: TimeInterval = 0
    var recording = false
    var busy = false
    var started: Date?
    var currentFile: URL?
    var lastAudio = Date()
    var timer: Timer?
    var meterTimer: Timer?
    var sleepAssertion: IOPMAssertionID = 0
    var observers: [NSObjectProtocol] = []
    var echoStream: EchoStream?
    var transcriptWindow: NSWindow?
    var transcriptView: NSTextView?
    var transcriptFile: URL?
    var transcriptText = ""
    var segmentCount = 0
    var statusItem: NSStatusItem!
    let idleMenuIcon = App.circleIcon(size: 18, recording: false)
    let recordingMenuIcon = App.circleIcon(size: 18, recording: true)
    let idleDockIcon = App.circleIcon(size: 128, recording: false)
    let recordingDockIcon = App.circleIcon(size: 128, recording: true)

    static func circleIcon(size: CGFloat, recording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            let inset = bounds.width * 0.15
            let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
            (recording ? NSColor.systemRed : NSColor.systemGray).setFill()
            circle.fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = recording ? "Recording" : "Not recording"
        return image
    }

    func updateRecordingIcons() {
        statusItem.button?.image = recording ? recordingMenuIcon : idleMenuIcon
        statusItem.button?.toolTip = recording ? "Lecture Recorder — Recording" : "Lecture Recorder — Not recording"
        statusItem.button?.setAccessibilityLabel(recording ? "Lecture Recorder: recording" : "Lecture Recorder: not recording")
        NSApp.applicationIconImage = recording ? recordingDockIcon : idleDockIcon
    }

    @objc func showRecorder() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        if let module = defaults.string(forKey: "lectureModule"), let week = defaults.object(forKey: "lectureWeek") as? Int, week > 0 {
            let moduleFolder = libraryRoot.appendingPathComponent(module, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: moduleFolder.path, isDirectory: &isDirectory), isDirectory.boolValue {
                selectedModule = module
                selectedWeek = week
                folder = moduleFolder.appendingPathComponent("Week \(week)", isDirectory: true)
            } else if let fallbackModule = selectedModule, let fallbackWeek = selectedWeek {
                defaults.set(fallbackModule, forKey: "lectureModule")
                defaults.set(fallbackWeek, forKey: "lectureWeek")
            }
        }
        let appMenu = NSMenu()
        let root = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit Lecture Recorder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = menu; appMenu.addItem(root); NSApp.mainMenu = appMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showRecorder)
        updateRecordingIcons()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Lecture Recorder"; window.delegate = self; window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor)])
        let title = NSTextField(labelWithString: "Lecture Recorder"); title.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        stack.addArrangedSubview(title)
        microphone.target = self; microphone.action = #selector(showMicrophoneMenu)
        microphone.isBordered = false; microphone.bezelStyle = .regularSquare
        microphone.widthAnchor.constraint(equalToConstant: 300).isActive = true
        microphone.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        microphone.setAccessibilityLabel("Select microphone")
        elapsed.font = .monospacedSystemFont(ofSize: 34, weight: .regular)
        stack.addArrangedSubview(elapsed)
        meter.widthAnchor.constraint(equalToConstant: 300).isActive = true
        meter.heightAnchor.constraint(equalToConstant: 8).isActive = true
        meter.setAccessibilityLabel("Microphone input level")
        stack.addArrangedSubview(meter)
        destinationLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        destinationLabel.lineBreakMode = .byTruncatingMiddle
        destinationLabel.alignment = .center
        destinationLabel.widthAnchor.constraint(equalToConstant: 300).isActive = true
        stack.addArrangedSubview(destinationLabel)
        transcriptionToggle.state = UserDefaults.standard.bool(forKey: "echoNote.enabled") ? .on : .off
        transcriptionToggle.target = self; transcriptionToggle.action = #selector(transcriptionChanged)
        transcriptionToggle.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(transcriptionToggle)
        transcriptButton.target = self; transcriptButton.action = #selector(showTranscript)
        transcriptButton.isBordered = false; transcriptButton.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        stack.addArrangedSubview(transcriptButton)
        newLecture.target = self; newLecture.action = #selector(createNewLecture); newLecture.isBordered = false; newLecture.bezelStyle = .regularSquare; newLecture.controlSize = .regular
        record.target = self; record.action = #selector(toggle); record.isBordered = false; record.bezelStyle = .regularSquare; record.controlSize = .regular
        reveal.target = self; reveal.action = #selector(openFolder); reveal.isBordered = false; reveal.bezelStyle = .regularSquare; reveal.controlSize = .regular
        for button in [newLecture, record, reveal] {
            button.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            button.widthAnchor.constraint(equalToConstant: 132).isActive = true
        }
        let actions = NSStackView(views: [newLecture, record, reveal]); actions.orientation = .vertical; actions.alignment = .centerX; actions.spacing = 4
        stack.addArrangedSubview(actions)
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular); status.textColor = .secondaryLabelColor
        status.alignment = .center
        let statusRow = NSStackView(views: [recordingDot, status])
        statusRow.orientation = .horizontal; statusRow.alignment = .centerY; statusRow.spacing = 6
        recordingDot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        recordingDot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        stack.addArrangedSubview(statusRow)
        stack.addArrangedSubview(microphone)
        window.setContentSize(NSSize(width: 380, height: 410))
        refreshFolderState()
        refreshDevices()
        capture.onLevel = { [weak self] value in self?.meter.setTarget(value); self?.lastAudio = Date() }
        capture.onPCM = { [weak self] samples, rate in self?.echoStream?.append(samples, rate: rate) }
        capture.onFailure = { [weak self] message in self?.finish(error: message) }
        for name in [Notification.Name.AVCaptureDeviceWasConnected, Notification.Name.AVCaptureDeviceWasDisconnected] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self = self else { return }
                if self.recording, name == .AVCaptureDeviceWasDisconnected, let d = note.object as? AVCaptureDevice, d.uniqueID == self.selectedMicrophoneID { self.finish(error: "The microphone disconnected. Recording stopped.") }
                if !self.recording && !self.busy { self.refreshDevices() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: nil, queue: .main) { [weak self] _ in self?.finish(error: "Audio capture was interrupted. Recording stopped.") })
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func transcriptionChanged() {
        let enabled = transcriptionToggle.state == .on
        UserDefaults.standard.set(enabled, forKey: "echoNote.enabled")
        guard !recording && !busy else { return }
        if enabled {
            let alert = NSAlert(); alert.messageText = "PC transcription settings"; alert.informativeText = "Enter the PC's Tailscale IP address and port." 
            let field = NSTextField(string: UserDefaults.standard.string(forKey: "echoNote.address") ?? "100.118.165.117:8765")
            field.frame = NSRect(x: 0, y: 0, width: 280, height: 24); alert.accessoryView = field
            alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { UserDefaults.standard.set(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "echoNote.address") }
            else { transcriptionToggle.state = .off; UserDefaults.standard.set(false, forKey: "echoNote.enabled") }
        }
    }
    @objc func showTranscript() {
        if transcriptWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Lecture Transcript"
            let scroll = NSScrollView(frame: w.contentView!.bounds); scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width, .height]
            let view = NSTextView(frame: scroll.contentView.bounds); view.isEditable = false; view.isSelectable = true; view.font = .systemFont(ofSize: 14); view.textContainerInset = NSSize(width: 12, height: 12); view.isRichText = false
            scroll.documentView = view; w.contentView?.addSubview(scroll); transcriptView = view; transcriptWindow = w
        }
        transcriptWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func receiveTranscript(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }
        transcriptText += (transcriptText.isEmpty ? "" : "\n") + clean
        transcriptView?.textStorage?.append(NSAttributedString(string: (segmentCount == 0 ? "" : "\n") + clean))
        segmentCount += 1
        if let transcriptFile, let handle = try? FileHandle(forWritingTo: transcriptFile) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data((clean + "\n").utf8)); try? handle.close() }
        transcriptButton.title = "Transcript window · \(segmentCount) segments"
    }
    func refreshDevices() {
        let selected = UserDefaults.standard.string(forKey: "microphone")
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified).devices
        if let selected, devices.contains(where: { $0.uniqueID == selected }) { selectedMicrophoneID = selected }
        else { selectedMicrophoneID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? devices.first?.uniqueID }
        updateMicrophoneButton()
        record.isEnabled = !devices.isEmpty
        microphone.isEnabled = !devices.isEmpty && !recording && !busy
        newLecture.isEnabled = !recording && !busy
        transcriptionToggle.isEnabled = !recording && !busy
        if devices.isEmpty { status.stringValue = "Connect a microphone to start" }
        else if status.stringValue == "Connect a microphone to start" { status.stringValue = "" }
    }
    func updateMicrophoneButton() {
        if let device = devices.first(where: { $0.uniqueID == selectedMicrophoneID }) {
            microphone.title = "MIC  ·  \(device.localizedName)  ▾"
            microphone.toolTip = device.localizedName
        } else {
            microphone.title = "No microphone available"
            microphone.toolTip = nil
        }
    }
    @objc func showMicrophoneMenu() {
        guard !recording && !busy else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for device in devices {
            let item = NSMenuItem(title: device.localizedName, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uniqueID
            item.state = device.uniqueID == selectedMicrophoneID ? .on : .off
            item.attributedTitle = NSAttributedString(string: device.localizedName, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: microphone.bounds.height), in: microphone)
    }
    @objc func selectMicrophone(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, devices.contains(where: { $0.uniqueID == id }) else { return }
        selectedMicrophoneID = id
        UserDefaults.standard.set(id, forKey: "microphone")
        updateMicrophoneButton()
    }
    var libraryRoot: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Lecture_Modules", isDirectory: true)
    }
    func childDirectories(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []
    }
    func existingModules() -> [String] {
        childDirectories(of: libraryRoot).filter { url in
            if childDirectories(of: url).contains(where: { $0.lastPathComponent.hasPrefix("Week ") }) { return true }
            return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).contains {
                URL(fileURLWithPath: $0).pathExtension.lowercased() == "wav"
            }
        }.map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    func existingWeeks(for module: String) -> [Int] {
        let moduleFolder = libraryRoot.appendingPathComponent(module, isDirectory: true)
        return childDirectories(of: moduleFolder).compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("Week "), let number = Int(name.dropFirst(5)), number > 0 else { return nil }
            return number
        }.sorted()
    }
    func makeComboBox(items: [String], value: String?) -> NSComboBox {
        let combo = NSComboBox()
        combo.isEditable = true; combo.completes = true; combo.font = .systemFont(ofSize: 12)
        combo.addItems(withObjectValues: items)
        if let value { combo.stringValue = value }
        combo.widthAnchor.constraint(equalToConstant: 230).isActive = true
        return combo
    }
    @objc func createNewLecture() {
        guard !recording && !busy else { return }
        let moduleBox = makeComboBox(items: existingModules(), value: selectedModule)
        let currentWeeks = selectedModule.map { existingWeeks(for: $0) } ?? []
        let weekBox = makeComboBox(items: currentWeeks.map { String($0) }, value: selectedWeek.map { String($0) })
        lectureWeekCombo = weekBox
        moduleBox.target = self; moduleBox.action = #selector(moduleSelectionChanged(_:))
        let moduleLabel = NSTextField(labelWithString: "Module")
        let weekLabel = NSTextField(labelWithString: "Week")
        for label in [moduleLabel, weekLabel] {
            label.font = .systemFont(ofSize: 12); label.widthAnchor.constraint(equalToConstant: 62).isActive = true
        }
        let moduleRow = NSStackView(views: [moduleLabel, moduleBox]); moduleRow.orientation = .horizontal; moduleRow.alignment = .centerY; moduleRow.spacing = 8
        let weekRow = NSStackView(views: [weekLabel, weekBox]); weekRow.orientation = .horizontal; weekRow.alignment = .centerY; weekRow.spacing = 8
        let fields = NSStackView(views: [moduleRow, weekRow]); fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 10
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 68))
        fields.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(fields)
        NSLayoutConstraint.activate([
            fields.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            fields.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            fields.topAnchor.constraint(equalTo: accessory.topAnchor),
            fields.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])
        let alert = NSAlert()
        alert.messageText = "New lecture"
        alert.informativeText = "Choose an existing module or type a new one, then choose or enter a week number."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Use lecture")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let module = moduleBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawWeek = weekBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let weekText = rawWeek.lowercased().hasPrefix("week ") ? String(rawWeek.dropFirst(5)) : rawWeek
            guard !module.isEmpty, module != ".", module != "..", !module.contains("/"), module.count <= 80,
                  let week = Int(weekText), week > 0 else {
                self.status.stringValue = "Enter a module name and a positive week number."
                return
            }
            let destination = self.libraryRoot.appendingPathComponent(module, isDirectory: true).appendingPathComponent("Week \(week)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                self.folder = destination
                self.selectedModule = module; self.selectedWeek = week
                self.currentFile = nil
                let defaults = UserDefaults.standard
                defaults.set(module, forKey: "lectureModule")
                defaults.set(week, forKey: "lectureWeek")
                self.refreshFolderState()
                self.status.stringValue = ""
            } catch {
                self.status.stringValue = "Could not create lecture folder: \(error.localizedDescription)"
            }
        }
    }
    @objc func moduleSelectionChanged(_ sender: NSComboBox) {
        guard let weekBox = lectureWeekCombo else { return }
        let typedWeek = weekBox.stringValue
        weekBox.removeAllItems()
        weekBox.addItems(withObjectValues: existingWeeks(for: sender.stringValue).map { String($0) })
        weekBox.stringValue = typedWeek
    }
    func folderAudioSummary() -> (fileCount: Int, duration: TimeInterval) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [])) ?? []
        var wavFiles: [URL] = []
        var cloudPlaceholders: [URL] = []
        for url in urls {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let name = url.lastPathComponent.lowercased()
            if name.hasSuffix(".wav.icloud") { cloudPlaceholders.append(url) }
            else if name.hasSuffix(".wav") { wavFiles.append(url) }
        }
        var duration = wavFiles.reduce(into: TimeInterval(0)) { total, url in
            guard let audioFile = try? AVAudioFile(forReading: url) else { return }
            let sampleRate = audioFile.processingFormat.sampleRate
            guard sampleRate.isFinite, sampleRate > 0 else { return }
            total += Double(audioFile.length) / sampleRate
        }
        // The recorder writes 48 kHz mono 16-bit PCM, so offloaded WAV sizes still give their duration.
        for url in cloudPlaceholders {
            guard let data = try? Data(contentsOf: url),
                  let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let values = propertyList as? [String: Any],
                  let fileSize = (values["NSURLFileSizeKey"] as? NSNumber)?.int64Value,
                  fileSize >= 44 else { continue }
            duration += Double(fileSize - 44) / 96_000.0
        }
        return (wavFiles.count + cloudPlaceholders.count, duration)
    }
    func formattedElapsed(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
    func refreshFolderState() {
        let summary = folderAudioSummary()
        elapsedBase = summary.duration
        elapsed.stringValue = formattedElapsed(summary.duration)
        updateDestinationDisplay(summary: summary)
    }
    func updateDestinationDisplay(summary: (fileCount: Int, duration: TimeInterval)? = nil) {
        let summary = summary ?? folderAudioSummary()
        let directoryName: String
        if let module = selectedModule, let week = selectedWeek {
            directoryName = "\(module) / Week \(week)  \(summary.fileCount)"
        } else {
            directoryName = "\(folder.lastPathComponent)  \(summary.fileCount)"
        }
        destinationLabel.attributedStringValue = NSAttributedString(
            string: directoryName,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        )
        destinationLabel.toolTip = currentFile.map { "\($0.path)\nSaved to \(folder.path)\n\(summary.fileCount) recording files" } ?? "\(folder.path)\n\(summary.fileCount) recording files"
    }
    @objc func openFolder() { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); NSWorkspace.shared.open(folder) }
    @objc func toggle() {
        guard !busy else { return }
        if recording { finish(error: nil); return }
        busy = true; record.isEnabled = false; microphone.isEnabled = false; newLecture.isEnabled = false; transcriptionToggle.isEnabled = false
        status.stringValue = "Checking microphone permission…"
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: begin()
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { allowed in DispatchQueue.main.async { if allowed { self.begin() } else { self.permissionDenied() } } }
        default: permissionDenied()
        }
    }
    func permissionDenied() {
        reset(); status.stringValue = "Microphone access is required."
        let alert = NSAlert(); alert.messageText = "Allow microphone access"; alert.informativeText = "Enable Lecture Recorder in System Settings → Privacy & Security → Microphone, then reopen the app."; alert.addButton(withTitle: "OK"); alert.runModal()
    }
    func begin() {
        guard let device = devices.first(where: { $0.uniqueID == selectedMicrophoneID }) else { reset(); status.stringValue = "Select a microphone to start"; return }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { reset(); status.stringValue = error.localizedDescription; return }
        let summary = folderAudioSummary()
        elapsedBase = summary.duration
        elapsed.stringValue = formattedElapsed(summary.duration)
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        var url = folder.appendingPathComponent("Lecture_\(date.string(from: Date())).wav")
        if FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("Lecture_\(date.string(from: Date()))_\(UUID().uuidString.prefix(6)).wav") }
        UserDefaults.standard.set(device.uniqueID, forKey: "microphone")
        currentFile = url; updateDestinationDisplay(summary: summary); status.stringValue = "Starting microphone…"
        transcriptText = ""; segmentCount = 0; transcriptFile = nil; transcriptView?.string = ""
        if transcriptionToggle.state == .on {
            let host = UserDefaults.standard.string(forKey: "echoNote.address") ?? "100.118.165.117:8765"
            guard let serverURL = URL(string: "ws://\(host)") else { prepareTranscriptFile(for: url); startLocalCapture(device: device, url: url, message: "Invalid PC address · recording locally"); return }
            let stream = EchoStream(url: serverURL); echoStream = stream
            stream.onText = { [weak self] text in self?.receiveTranscript(text) }
            stream.onStatus = { [weak self] message in self?.status.stringValue = "Recording · \(message)" }
            stream.connect { error in
                DispatchQueue.main.async {
                    if let error { self.echoStream = nil; self.prepareTranscriptFile(for: url); self.startLocalCapture(device: device, url: url, message: "Recording locally · PC unavailable: \(error)") }
                    else { self.prepareTranscriptFile(for: url); self.startLocalCapture(device: device, url: url, message: "Recording · transcribing on PC") }
                }
            }
            return
        }
        echoStream = nil
        startLocalCapture(device: device, url: url, message: "Recording")
    }
    func startLocalCapture(device: AVCaptureDevice, url: URL, message: String) {
        capture.start(device: device, url: url) { error in
            if let error = error { self.reset(); self.refreshFolderState(); self.status.stringValue = error; return }
            self.busy = false; self.recording = true; self.started = Date(); self.lastAudio = Date()
            if self.transcriptionToggle.state == .on { self.showTranscript() }
            self.updateDestinationDisplay()
            self.updateRecordingIcons()
            self.meterTimer?.invalidate()
            self.meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.meter.animateFrame() }
            self.recordingDot.isRecording = true
            self.record.isEnabled = true; self.record.title = "Stop & Save"; self.status.stringValue = message
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Lecture recording" as CFString, &self.sleepAssertion)
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        }
    }
    func prepareTranscriptFile(for audioURL: URL) {
        let url = audioURL.deletingPathExtension().appendingPathExtension("txt")
        let header = "EchoNote transcript\nCreated: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))\n\n"
        do { try Data(header.utf8).write(to: url, options: .atomic); transcriptFile = url }
        catch { status.stringValue = "Recording · transcript backup unavailable: \(error.localizedDescription)" }
    }
    func tick() {
        guard let started = started else { return }
        let recordingSeconds = Date().timeIntervalSince(started)
        elapsed.stringValue = formattedElapsed(elapsedBase + recordingSeconds)
        if Date().timeIntervalSince(lastAudio) > 10 { finish(error: "No audio arrived for 10 seconds. Recording stopped; check the microphone.") }
        // Stay below the classic WAV size limit, even for unusually long sessions.
        if recordingSeconds >= 10 * 3600 { finish(error: "The 10-hour recording limit was reached. Start a new recording to continue.") }
    }
    func finish(error: String?) {
        guard recording && !busy else { return }
        busy = true; record.isEnabled = false; timer?.invalidate(); timer = nil
        status.stringValue = "Saving…"
        capture.stop { success, hadAudio in
            self.echoStream?.finish(); self.echoStream = nil
            self.reset()
            self.refreshFolderState()
            if let error = error { self.status.stringValue = error }
            else if success { self.status.stringValue = "Saved " + (self.currentFile?.lastPathComponent ?? "recording") }
            else if hadAudio { self.status.stringValue = "Save failed. A partial WAV may remain in the folder." }
            else { self.status.stringValue = "No audio was received; no recording was saved." }
            if let error = error { let alert = NSAlert(); alert.messageText = "Recording stopped"; alert.informativeText = error + (success ? " The captured audio was saved." : " Check the save folder for a partial recording."); alert.runModal() }
        }
    }
    func reset() {
        recording = false; busy = false; started = nil
        recordingDot.isRecording = false
        meterTimer?.invalidate(); meterTimer = nil; meter.reset()
        updateRecordingIcons()
        record.title = "Record"; record.isEnabled = !devices.isEmpty; microphone.isEnabled = !devices.isEmpty; newLecture.isEnabled = true; transcriptionToggle.isEnabled = true
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy { return .terminateCancel }
        guard recording else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Stop and save before quitting?"; alert.addButton(withTitle: "Stop, Save & Quit"); alert.addButton(withTitle: "Keep Recording")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        busy = true; timer?.invalidate()
        capture.stop { success, hadAudio in
            self.echoStream?.finish(); self.echoStream = nil
            self.reset()
            if !success { let a = NSAlert(); a.messageText = hadAudio ? "Recording could not be fully saved" : "No audio was received"; a.informativeText = "Check your save folder before closing the app."; a.runModal() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
}

let application = NSApplication.shared
let delegate = App()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
