//
//  BishopAPI.swift
//  Everything that talks to the Mac: the token, the JSON calls and the SSE
//  stream. One client object is shared by the whole app.
//
//  The server is webui.py; the endpoints are the ones webui.html uses, so the
//  phone and the browser stay in step:
//
//    GET  /api/state              session + transcript + usage + effort
//    GET  /api/sessions           recent sessions for the picker
//    GET  /api/events             the transcript rebuilt from the logs
//    GET  /api/image?p=<path>     one picture
//    GET  /api/stream             server-sent events: the live turn
//    POST /api/chat               {text|paths|session|reset} - starts/queues a turn
//    POST /api/upload             raw image bytes -> saved path
//    POST /api/effort             {effort}
//    POST /api/speech/stop        shut Bishop up
//    POST /api/restart            reload the server (and so a webui.py change)
//

import Foundation

struct ChatEvent: Identifiable, Equatable {
    enum Kind: Equatable { case user, reasoning, content, tool, toolResult, image, info, error }
    let id = UUID()
    var kind: Kind
    var text = ""
    var imagePath = ""
    var name = ""

    static func == (a: ChatEvent, b: ChatEvent) -> Bool { a.id == b.id }
}

struct SessionInfo: Identifiable, Hashable {
    var id: String
    var title: String
}

struct UsageStats {
    var calls = 0
    var input = 0
    var output = 0
    var cached = 0
    var sessionCost = ""
    var lastInput = 0
    var lastOutput = 0
    var lastCost = ""
}

@MainActor
final class BishopAPI: ObservableObject {
    @Published var host = ""                 // e.g. "192.168.2.12:8420" or "bishop.local:8420"
    @Published var token = ""
    @Published var connected = false
    @Published var lastError = ""
    @Published var busy = false
    @Published var session = ""
    @Published var sessions: [SessionInfo] = []
    @Published var effort = "high"
    @Published var levels: [String] = []
    @Published var usage: UsageStats?
    @Published var liveTokens = 0            // counted on the Mac while Bishop writes
    @Published var liveRate = 0.0

    private let stream = StreamClient()
    private let session_ = URLSession(configuration: .default)
    let bonjour = Bonjour()          // finds the Mac without knowing its IP


    // MARK: address book

    /// Where the Mac might be, most trustworthy first: the address that worked
    /// last time, then whatever Bonjour found just now (that is what survives a
    /// new DHCP lease), then the mDNS name of the Mac and the last-resort ones.
    var candidates: [String] {
        var out: [String] = []
        let saved = UserDefaults.standard.string(forKey: "host") ?? ""
        if !saved.isEmpty { out.append(saved) }
        out.append(contentsOf: bonjour.found)
        for h in ["Alexs-MacBook-Pro.local:8420", "MacBook-Pro.local:8420", "127.0.0.1:8420"]
        where !out.contains(h) { out.append(h) }
        return out
    }

    /// The address and token last used. Read once, here: connect() must never
    /// re-read them, or it would throw away what Alex just typed in. The
    /// BISHOP_HOST / BISHOP_TOKEN environment wins when set, which is how the
    /// simulator is driven from a script (xcrun simctl launch with SIMCTL_CHILD_*).
    init() {
        let env = ProcessInfo.processInfo.environment
        host = env["BISHOP_HOST"] ?? UserDefaults.standard.string(forKey: "host") ?? ""
        token = env["BISHOP_TOKEN"] ?? UserDefaults.standard.string(forKey: "token") ?? ""
    }

    func save() {
        UserDefaults.standard.set(host, forKey: "host")
        UserDefaults.standard.set(token, forKey: "token")
    }

    /// Try every candidate address once; keep the first that answers /api/state.
    func connect() async {
        save()
        if !connected { bonjour.start(); try? await Task.sleep(nanoseconds: 1_200_000_000) }
        guard !token.isEmpty else { lastError = "No token: type the one in ~/.bishop_web_token."; return }
        for h in candidates {
            do {
                let state = try await get("/api/state", base: h)
                host = h
                save()
                connected = true
                lastError = ""
                applyState(state)
                return
            } catch {
                lastError = "\(h): \(error.localizedDescription)"
            }
        }
        connected = false
    }

    // MARK: plain calls

    private func url(_ path: String, base: String? = nil) -> URL {
        let b = base ?? host
        let q = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        return URL(string: "http://\(b)\(path)\(path.contains("?") ? "&" : "?")t=\(q)")!
    }

    private func get(_ path: String, base: String? = nil) async throws -> [String: Any] {
        let (data, _) = try await session_.data(from: url(path, base: base))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        if let e = obj["error"] as? String { throw NSError(domain: "bishop", code: 1, userInfo: [NSLocalizedDescriptionKey: e]) }
        return obj
    }

    @discardableResult
    func post(_ path: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        var r = URLRequest(url: url(path))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session_.data(for: r)
        // A turn in flight answers {"error":"busy"} with a 409; anything else
        // with a status is a real failure the chat should show.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let e = obj["error"] as? String { throw NSError(domain: "bishop", code: 1, userInfo: [NSLocalizedDescriptionKey: e]) }
        guard status < 400 else { throw NSError(domain: "bishop", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]) }
        return obj
    }

    // MARK: what the UI needs

    func applyState(_ s: [String: Any]) {
        session = s["session"] as? String ?? ""
        busy = s["busy"] as? Bool ?? false
        effort = s["effort"] as? String ?? effort
        levels = s["levels"] as? [String] ?? levels
        sessions = (s["sessions"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return SessionInfo(id: id, title: $0["title"] as? String ?? id)
        }
        if let u = s["usage"] as? [String: Any] {
            usage = UsageStats(calls: u["calls"] as? Int ?? 0,
                               input: u["input"] as? Int ?? 0,
                               output: u["output"] as? Int ?? 0,
                               cached: u["cached"] as? Int ?? 0,
                               sessionCost: u["cost_total"] as? String ?? "",
                               lastInput: u["last_input"] as? Int ?? 0,
                               lastOutput: u["last_output"] as? Int ?? 0,
                               lastCost: u["last_cost"] as? String ?? "")
        }
    }

    /// The stored transcript of a session, as the same event shapes the live
    /// stream uses (the server rebuilds it from the history + raw logs).
    func events(session id: String?) async throws -> ([ChatEvent], String) {
        let obj: [String: Any]
        if let id {
            let r = try await post("/api/chat", ["session": id])
            obj = ["events": r["events"] as? [[String: Any]] ?? [], "session": id]
        } else {
            obj = try await get("/api/events")
        }
        return (Self.decode(obj["events"] as? [[String: Any]] ?? []), obj["session"] as? String ?? "")
    }

    static func decode(_ raw: [[String: Any]]) -> [ChatEvent] {
        raw.compactMap { e in
            guard let type = e["type"] as? String else { return nil }
            switch type {
            case "user":        return ChatEvent(kind: .user, text: e["text"] as? String ?? "")
            case "reasoning":   return ChatEvent(kind: .reasoning, text: e["text"] as? String ?? "")
            case "content":     return ChatEvent(kind: .content, text: e["text"] as? String ?? "")
            case "tool":        return ChatEvent(kind: .tool, text: e["arguments"] as? String ?? "", name: e["name"] as? String ?? "tool")
            case "tool_result": return ChatEvent(kind: .toolResult, text: e["result"] as? String ?? "")
            case "image":       return ChatEvent(kind: .image, imagePath: e["path"] as? String ?? "")
            case "info":        return ChatEvent(kind: .info, text: e["text"] as? String ?? "")
            case "error":       return ChatEvent(kind: .error, text: e["text"] as? String ?? "")
            default:            return nil
            }
        }
    }

    func imageURL(_ path: String) -> URL { url("/api/image?p=\(path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path)") }

    // MARK: sending

    /// Returns nil on success, else a message for the chat: "busy" is the one
    /// case that is not a failure - a turn is already running (that can be
    /// Bishop's own turn in the terminal), and the stream will show it.
    func send(text: String, paths: [String] = []) async -> String? {
        do {
            _ = try await post("/api/chat", ["text": text, "paths": paths])
            liveTokens = 0
            return nil
        } catch {
            let msg = error.localizedDescription
            return msg == "busy" ? "Bishop is still answering - the next message is not queued." : msg
        }
    }

    func newChat() async {
        _ = try? await post("/api/chat", ["reset": true])
    }

    func load(session id: String) async {
        _ = try? await post("/api/chat", ["session": id])
    }

    func setEffort(_ e: String) async {
        if let r = try? await post("/api/effort", ["effort": e]) {
            effort = r["effort"] as? String ?? effort
        }
    }

    func stopSpeech() async { _ = try? await post("/api/speech/stop") }
    func restartServer() async { _ = try? await post("/api/restart") }

    /// Raw bytes (a photo) as an upload; returns the path the Mac saved it to.
    func upload(_ data: Data) async -> String? {
        var r = URLRequest(url: url("/api/upload"))
        r.httpMethod = "POST"
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.httpBody = data
        guard let (d, _) = try? await session_.data(for: r),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let path = obj["path"] as? String else { return nil }
        return path
    }

    /// /api/state again, after a restart or a session switch.
    func refresh() async {
        guard connected, let s = try? await get("/api/state") else { return }
        applyState(s)
    }

    // MARK: the live stream

    /// Server-sent events, exactly as webui.html consumes them: start, reasoning,
    /// content, tool, tool_result, image, info, error, usage, live, done, end.
    /// The stream replays the turn in flight from its 'start', so reconnecting
    /// mid-answer misses nothing. Callbacks arrive on the main queue.
    func startStream(onEvent: @escaping (ChatEvent) -> Void,
                     onStart: @escaping () -> Void,
                     onEnd: @escaping () -> Void) {
        stream.onJSON = { [weak self] obj in
            guard let self, let type = obj["type"] as? String else { return }
            switch type {
            case "start":  onStart()
            case "end":    onEnd()
            case "usage":  if let u = obj["stats"] as? [String: Any] { self.applyStats(u) }
            case "live":
                self.liveTokens = obj["tokens"] as? Int ?? 0
                self.liveRate = obj["rate"] as? Double ?? 0
            case "busy", "switched", "done": break
            default:
                for e in Self.decode([obj]) { onEvent(e) }
            }
        }
        // The server closing on us is normal (it restarts): reconnect rather
        // than go silent, and let the replay fill in whatever was missed.
        stream.onEnded = {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.openStream()
            }
        }
        openStream()
    }

    private func openStream() {
        stream.open(url("/api/stream"))
    }

    private func applyStats(_ u: [String: Any]) {
        usage = UsageStats(calls: u["calls"] as? Int ?? 0,
                           input: u["input"] as? Int ?? 0,
                           output: u["output"] as? Int ?? 0,
                           cached: u["cached"] as? Int ?? 0,
                           sessionCost: u["cost_total"] as? String ?? "",
                           lastInput: u["last_input"] as? Int ?? 0,
                           lastOutput: u["last_output"] as? Int ?? 0,
                           lastCost: u["last_cost"] as? String ?? "")
    }
}
