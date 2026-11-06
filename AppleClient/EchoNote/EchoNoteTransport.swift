import Foundation

enum EchoNoteConfiguration {
    static let serverAddress = "ws://100.118.165.117:8765"
    static let serverURL = URL(string: serverAddress)!
}

enum EchoNoteHealthCheck {
    static func check(url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let body = try JSONSerialization.data(withJSONObject: ["type": "health"])
        guard let json = String(data: body, encoding: .utf8) else {
            throw ClientError.server("Could not prepare the connection check.")
        }
        try await task.send(.string(json))

        let reply = try await task.receive()
        guard case .string(let response) = reply,
              let data = response.data(using: .utf8),
              let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.server("The PC returned an invalid connection check response.")
        }
        if message["type"] as? String == "error" {
            let description = message["message"] as? String ?? "PC rejected the connection check."
            throw ClientError.server(description)
        }
        guard message["type"] as? String == "health",
              message["status"] as? String == "ready" else {
            throw ClientError.server("PC returned an unexpected connection check response.")
        }
    }
}

enum ServerEvent: Sendable {
    case transcript(index: Int, text: String)
    case final(failed: [Int])
    case error(String)
    case disconnected(String)
}

actor EchoNoteTransport {
    let events: AsyncStream<ServerEvent>
    private let eventContinuation: AsyncStream<ServerEvent>.Continuation
    private var socket: URLSessionWebSocketTask?
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var writer: Task<Void, Never>?
    private let maximumPendingBytes = 2 * 1_024 * 1_024

    init() {
        var continuation: AsyncStream<ServerEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func connect(url: URL, sessionID: String) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        let start: [String: Any] = [
            "type": "start", "protocol_version": 1, "session_id": sessionID,
            "sample_rate": 16_000, "channels": 1, "sample_format": "s16le"
        ]
        try await task.send(.string(try Self.json(start)))
        let reply = try await task.receive()
        guard case .string(let json) = reply,
              let message = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ClientError.server("The server sent an invalid start response.")
        }
        if message["type"] as? String == "error" {
            throw ClientError.server(message["message"] as? String ?? "The server rejected the connection.")
        }
        guard message["type"] as? String == "started", message["protocol_version"] as? Int == 1,
              message["session_id"] as? String == sessionID else {
            throw ClientError.server("The server response did not match this session.")
        }
        Task { await self.receiveLoop() }
    }

    func enqueueAudio(_ data: Data) throws {
        guard socket != nil else { throw ClientError.server("The connection is closed.") }
        guard pendingBytes + data.count <= maximumPendingBytes else {
            throw ClientError.server("Network is too slow; stopped before audio could be silently dropped.")
        }
        pending.append(data)
        pendingBytes += data.count
        if writer == nil { writer = Task { await self.drainAudio() } }
    }

    func finish(sessionID: String) async throws {
        while writer != nil { try await Task.sleep(for: .milliseconds(20)) }
        guard let socket else { return }
        try await socket.send(.string(try Self.json(["type": "stop", "session_id": sessionID])))
    }

    func disconnect() {
        writer?.cancel()
        writer = nil
        pending.removeAll()
        pendingBytes = 0
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        eventContinuation.finish()
    }

    private func drainAudio() async {
        while !pending.isEmpty, let socket {
            let data = pending.removeFirst()
            pendingBytes -= data.count
            do { try await socket.send(.data(data)) }
            catch {
                eventContinuation.yield(.error(error.localizedDescription))
                socket.cancel(with: .goingAway, reason: nil)
                self.socket = nil
                pending.removeAll()
                pendingBytes = 0
                break
            }
        }
        writer = nil
    }

    private func receiveLoop() async {
        guard let socket else { return }
        do {
            while true {
                let message = try await socket.receive()
                guard case .string(let json) = message,
                      let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { continue }
                switch value["type"] as? String {
                case "transcript_segment":
                    if let index = value["segment_index"] as? Int, let text = value["text"] as? String {
                        eventContinuation.yield(.transcript(index: index, text: text))
                    }
                case "error":
                    eventContinuation.yield(.error(value["message"] as? String ?? "Server error."))
                case "final":
                    eventContinuation.yield(.final(failed: value["failed_segment_indices"] as? [Int] ?? []))
                    eventContinuation.finish()
                    socket.cancel(with: .normalClosure, reason: nil)
                    self.socket = nil
                    return
                default: break
                }
            }
        } catch {
            eventContinuation.yield(.disconnected(error.localizedDescription))
            eventContinuation.finish()
            socket.cancel(with: .goingAway, reason: nil)
            self.socket = nil
            writer?.cancel()
            writer = nil
            pending.removeAll()
            pendingBytes = 0
        }
    }

    private static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let result = String(data: data, encoding: .utf8) else {
            throw ClientError.server("Could not encode the server message.")
        }
        return result
    }
}
