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
//    POST /api/chat/stop          stop the turn in flight
//    POST /api/restart            reload the server (and so a webui.py change)
//

import Foundation

/// One row of the transcript. The kinds mirror what the server emits, but not
/// one to one: a turn is a sequence of PHASES (thought, answer, tool, result),
/// and rows are grouped that way so a thought folds as one line instead of the
/// transcript turning into a wall of loose fragments.
struct ChatEvent: Identifiable {
    enum Kind { case user, thought, answer, tool, detail, image, info, error }
    let id = UUID()
    var kind: Kind
    var text = ""               // reasoning, answer, tool arguments, result, info
    var name = ""               // tool name, detail summary, image caption
    var imagePath = ""
    var open = false            // a thought or a fold the user can open
    var watched = false         // a thought this app saw streaming, so its clock is its own
    var secs = 0                // how long it ran, once folded, and only when measured
    var started = Date()
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


    // MARK: address book

    /// The Mac's address. Edit this one line to move the app somewhere else;
    /// the rest of `candidates` is fallback. The port lives in the address
    /// because webui.py writes the one it actually chose to ~/.bishop_web_port.
    static let DEFAULT_HOST = "192.168.2.12:8420"

    /// Where the Mac might be, in the order worth trying: what Alex last typed
    /// (or the last address that answered), then DEFAULT_HOST, then the Mac's
    /// Bonjour name - which follows a new DHCP lease without any discovery code -
    /// and finally localhost, which is where the simulator sees the Mac.
    ///
    /// The .local name is tried LAST on purpose: on a real phone it resolves
    /// fine, but it resolves to the Mac's OWN address whatever this device is
    /// (Bonjour on the Mac publishes every interface), so 127.0.0.1 inside the
    /// (fall)back list resolves to the phone itself and costs a connection
    /// timeout whenever it is reached.
    var candidates: [String] {
        let saved = UserDefaults.standard.string(forKey: "host") ?? ""
        var out = [saved, Self.DEFAULT_HOST, "Alexs-MacBook-Pro.local:8420"]
        #if targetEnvironment(simulator)
        out.append("127.0.0.1:8420")     // the simulator shares the Mac's loopback
        #endif
        return out.filter { !$0.isEmpty }
    }

    /// The address and token last used. Read once, here: connect() must never
    /// re-read them, or it would throw away what Alex just typed in.
    ///
    /// The first NON-EMPTY value wins: the environment (SIMCTL_CHILD_* drives the
    /// simulator from a script), then what was saved, then what the build baked
    /// into Info.plist. Emptiness matters - the very first run of a build with no
    /// token saved "" into UserDefaults, and because "" is not nil it then
    /// shadowed the token baked into every later build, so the app sat on "Not
    /// connected" until the token was pasted by hand on the phone's keyboard.
    init() {
        let env = ProcessInfo.processInfo.environment
        func pick(_ values: String?...) -> String {
            for v in values where !(v ?? "").isEmpty { return v! }
            return ""
        }
        host = pick(env["BISHOP_HOST"], UserDefaults.standard.string(forKey: "host"),
                    Bundle.main.object(forInfoDictionaryKey: "BISHOP_HOST") as? String)
        token = pick(env["BISHOP_TOKEN"], UserDefaults.standard.string(forKey: "token"),
                     Bundle.main.object(forInfoDictionaryKey: "BISHOP_TOKEN") as? String)
    }

    /// Remember only what is worth remembering: saving "" would shadow the token
    /// the build baked into Info.plist (see init), so a phone with nothing to
    /// remember is not "helped" into having nothing to use.
    func save() {
        if !host.isEmpty { UserDefaults.standard.set(host, forKey: "host") }
        if !token.isEmpty { UserDefaults.standard.set(token, forKey: "token") }
    }

    /// Try every candidate address once; keep the first that answers /api/state.
    func connect() async {
        save()
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
    /// stream uses (the server rebuilds it from the history + raw logs). The
    /// reply's own session/usage is applied as well: switching to a session the
    /// server does not know comes back with a DIFFERENT id, and the picker has
    /// to follow that or it shows the wrong title.
    ///
    /// This was also where the app looked frozen on a long session: it waited
    /// for /api/events - which took 17 s, because resolving an image path walked
    /// the whole home directory (see vision._resolve). The wait was the server's,
    /// not the app's, but the app asked for state (fast) and events (slow) in one
    /// go, so nothing drew until both came back.
    func events(session id: String?) async throws -> ([ChatEvent], String) {
        let obj: [String: Any]
        if let id {
            let r = try await post("/api/chat", ["session": id])
            applyState(r)
            obj = r
        } else {
            obj = try await get("/api/events")
        }
        return (Self.decode(obj["events"] as? [[String: Any]] ?? []), obj["session"] as? String ?? "")
    }

    /// Tool calls, results, info and errors coming out of a stored session.
    /// The whole list is grouped in one pass, exactly as the live stream is, so
    /// replaying a session and watching it happen produce the same rows.
    static func decode(_ raw: [[String: Any]]) -> [ChatEvent] { group(raw) }

    /// The one renderer, shared by the replay and the live stream: group the
    /// events into phases the way webui.html does. The stream sends one token
    /// per event, so feeding them all in at once is the same as receiving them
    /// one by one - and one code path means it cannot drift.
    ///
    /// Rules, all lifted from the web UI: consecutive reasoning is ONE thought
    /// (folded as soon as the answer or a tool starts); consecutive content is
    /// ONE answer bubble; a tool call ends the thought and closes the answer, so
    /// the text after a call is a new bubble; a result with no text is dropped.
    static func group(_ raw: [[String: Any]]) -> [ChatEvent] {
        var out: [ChatEvent] = []
        var thought: Int?      // index of the thought taking text right now, nil once closed
        var answer: Int?       // same, for the answer bubble
        // `secs` is NOT set here: this pass groups a live BATCH as well as a
        // replay, and folding one on arrival stamped every thought with the
        // second it had been in the array - which is why a running thought read
        // "thought for 1s" from its first token (and still, after grouping, kept
        // that number while it ran). A stored session has no timings to give, so
        // it keeps 0 and the block says "thought"; a live one is timed by
        // ChatView.closePhase, which knows when the thought started.
        func closeThought() {
            if let i = thought { out[i].open = false }
            thought = nil
        }
        func closeAnswer() { answer = nil }

        for e in raw {
            switch e["type"] as? String ?? "" {
            case "user":
                closeThought(); closeAnswer()
                out.append(ChatEvent(kind: .user, text: e["text"] as? String ?? ""))
            case "reasoning":
                closeAnswer()
                if thought == nil { out.append(ChatEvent(kind: .thought, open: true)); thought = out.count - 1 }
                out[thought!].text += e["text"] as? String ?? ""
            case "content":
                closeThought()
                let t = e["text"] as? String ?? ""
                // A bubble that so far holds only whitespace is not shown at all
                // (webui.html grow(): node.hidden): blank answers would otherwise
                // leave empty gaps all over the transcript.
                if let i = answer { out[i].text += t }
                else if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(ChatEvent(kind: .answer, text: t)); answer = out.count - 1
                }
            case "tool":
                // Also shows Bishop's work from sessions with no stored events,
                // where tools arrive as "<name> {...}" lines of the answer text.
                closeThought(); closeAnswer()
                out.append(ChatEvent(kind: .tool, text: e["arguments"] as? String ?? "",
                                     name: e["name"] as? String ?? "tool"))
            case "tool_result":
                let body = (e["result"] as? String) ?? ""
                closeThought(); closeAnswer()
                out.append(ChatEvent(kind: .detail, text: body, name: "result"))
            case "image":
                out.append(ChatEvent(kind: .image, name: e["title"] as? String ?? "",
                                     imagePath: e["path"] as? String ?? ""))
            case "info":
                out.append(ChatEvent(kind: .info, text: e["text"] as? String ?? ""))
            case "error":
                out.append(ChatEvent(kind: .error, text: e["text"] as? String ?? ""))
            default: break          // start / end / live / usage / busy are not rows
            }
        }
        closeThought()              // a turn that ended mid-thought still folds
        return out
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
            return nil        } catch {
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

    /// Stop the turn in flight (the composer's square button). The Mac keeps what
    /// was written so far as the answer, ends the turn, and the stream's 'end'
    /// event clears `busy` - so this only has to send the request.
    func stopTurn() async {
        _ = try? await post("/api/chat/stop")
    }

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
    ///
    /// Rows are grouped here too, by running the fresh events through the same
    /// `group` as a replay - so a live turn and a reopened session cannot render
    /// differently, which is what the first version got wrong.
    func startStream(onEvents: @escaping ([ChatEvent]) -> Void,
                     onLive: @escaping () -> Void,
                     onStart: @escaping () -> Void,
                     onEnd: @escaping () -> Void) {
        var batch: [[String: Any]] = []      // reasoning/content tokens, flushed per frame
        func flush() {
            guard !batch.isEmpty else { return }
            onEvents(Self.group(batch))
            batch = []
        }
        stream.onJSON = { [weak self] obj in
            guard let self, let type = obj["type"] as? String else { return }
            switch type {
            case "start":  flush(); onStart()
            case "end", "done": flush(); onEnd()
            case "usage":  if let u = obj["stats"] as? [String: Any] { self.applyStats(u) }
            case "live":
                // Only a genuinely running turn produces these (the server sends
                // the first one a fraction of a second into the first reasoning
                // token), so this is the signal that the rows on screen are being
                // WRITTEN rather than replayed - the one thing the events
                // themselves do not say. See ChatView.markWatched.
                let first = self.liveTokens == 0 && (obj["tokens"] as? Int ?? 0) > 0
                self.liveTokens = obj["tokens"] as? Int ?? 0
                self.liveRate = obj["rate"] as? Double ?? 0
                if first { onLive() }
            case "busy", "switched": break
            default:
                batch.append(obj)
                // The token does not know whether more of it is coming, so the
                // rows go out on the next runloop pass: a whole burst of tokens
                // then lands in ONE row instead of being regrouped per token.
                DispatchQueue.main.async { flush() }
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
