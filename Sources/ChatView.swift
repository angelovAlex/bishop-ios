//
//  ChatView.swift
//  The chat: transcript, live stream, composer. One screen, no tabs.
//

import PhotosUI
import SwiftUI

struct ChatView: View {
    @StateObject private var api = BishopAPI()
    @State private var events: [ChatEvent] = []
    @State private var draft = ""
    @State private var attachments: [(path: String, name: String)] = []
    @State private var picker: [PhotosPickerItem] = []
    @State private var showStats = false
    @State private var fullPicture: String?
    @State private var thinking = false         // Bishop's thoughts: collapsed until asked
    @State private var atBottom = true

    var body: some View {
        VStack(spacing: 0) {
            header
            if api.busy { liveBanner }
            transcript
            statsStrip
            composer
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .task { await api.connect(); await reload() }
        .onAppear { startStream() }
        .sheet(item: Binding(get: { fullPicture.map(PicturePath.init) }, set: { fullPicture = $0?.path })) {
            PictureView(path: $0.path, api: api)
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                Task { await api.newChat(); events = []; api.session = ""
                       events = [ChatEvent(kind: .info, text: "New conversation.")] }
            } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.bordered).buttonBorderShape(.circle)

            Menu {
                ForEach(api.sessions) { s in
                    Button(s.title) { Task { await open(s.id) } }
                }
            } label: {
                Text(title).lineLimit(1).font(.footnote).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule)

            Button { Task { await api.stopSpeech() } } label: { Image(systemName: "speaker.slash") }
                .buttonStyle(.bordered).buttonBorderShape(.circle)

            Button { Task { await api.restartServer() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.bordered).buttonBorderShape(.circle)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .tint(.gray)
    }

    /// A turn is in flight somewhere (here, the terminal, or another phone):
    /// its words land at the END of the transcript, so say so at the top.
    private var liveBanner: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini).tint(.gray)
            Text(liveLine).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.bottom, 4)
        .foregroundStyle(.gray)
    }

    /// The live counter belongs here, not in the stats strip: that one is a
    /// single line of fixed figures, and a moving number made it wrap.
    private var liveLine: String {
        var s = "Bishop is writing now - the answer appears at the bottom"
        if api.liveTokens > 0 {
            s = String(format: "live %dk tok at %.1f tok/s", api.liveTokens / 1000, api.liveRate)
            if api.liveTokens < 1000 { s = String(format: "live %d tok at %.1f tok/s", api.liveTokens, api.liveRate) }
        }
        return s
    }

    private var title: String {
        api.sessions.first { $0.id == api.session }?.title ?? (api.session.isEmpty ? "Bishop" : api.session)
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !api.connected {
                        ConnectBanner(api: api)
                    }
                    ForEach(events) { e in
                        EventRow(event: e, api: api, thinking: $thinking, fullPicture: $fullPicture)
                            .id(e.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12).padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: events.count) { withAnimation(.linear(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: events.last?.text) { withAnimation(.linear(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    // MARK: counters (one dim line, tap for the report)

    private var statsStrip: some View {
        Button { withAnimation { showStats.toggle() } } label: {
            HStack(spacing: 8) {
                if let u = api.usage {
                    Text("calls \(u.calls)").bold()
                    Text("in \(short(u.input))").bold()
                    Text("out \(short(u.output))").bold()
                    Text(u.sessionCost).bold()
                    Spacer()
                    Image(systemName: showStats ? "chevron.up" : "chevron.right").font(.caption2)
                } else {
                    Text("no call yet").bold(); Spacer()
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.gray)
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 14).padding(.bottom, 4)
        }
        .buttonStyle(.plain)
    }

    private func short(_ v: Int) -> String {
        if v < 1000 { return "\(v)" }
        if v < 1_000_000 { return String(format: "%.1fk", Double(v) / 1000) }
        return String(format: "%.2fM", Double(v) / 1_000_000)
    }

    // MARK: composer

    private var composer: some View {
        VStack(spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments, id: \.path) { a in
                            AsyncImage(url: api.imageURL(a.path)) { $0.resizable().scaledToFill() }
                                placeholder: { Color.gray }
                                .frame(height: 54).frame(width: 54).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .topTrailing) {
                                    Button { attachments.removeAll { $0.path == a.path } } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .gray)
                                    }.padding(2)
                                }
                        }
                    }.padding(.horizontal, 12)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $picker, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                        .frame(width: 34, height: 34).background(Color(white: 0.2)).clipShape(.circle)
                }
                TextField("Message Bishop", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 8)
                    .font(.system(size: 16, design: .monospaced))   // 16pt: iOS never zoom-scales
                    .submitLabel(.send)
                    .onSubmit { send() }        // a hardware keyboard's return sends
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                        .frame(width: 34, height: 34).background(.white).foregroundStyle(.black).clipShape(.circle)
                }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty && attachments.isEmpty)
            }
            .padding(8)
            .background(Color(white: 0.11))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 10)
        }
        .padding(.bottom, 6)
        .onChange(of: picker) { _, items in Task { await addPhotos(items); picker = [] } }
    }

    // MARK: actions

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = attachments.map(\.path)
        guard !text.isEmpty || !paths.isEmpty else { return }
        draft = ""
        attachments = []
        // The event stream replays the turn, but the user's own line is not
        // echoed back mid-turn, so show it at once.
        events.append(ChatEvent(kind: .user, text: text))
        for p in paths { events.append(ChatEvent(kind: .image, imagePath: p)) }
        Task {
            if let problem = await api.send(text: text, paths: paths) {
                events.append(ChatEvent(kind: .info, text: problem))
            }
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let path = await api.upload(data) {
                attachments.append((path, "photo"))
            }
        }
    }

    private func open(_ id: String) async {
        await api.load(session: id)
        await reload()
    }

    private func reload() async {
        if let (list, sess) = try? await api.events(session: nil) {
            events = list
            api.session = sess
            await api.refresh()          // counters, session list, effort
        }
    }

    /// The stream replays the turn in flight, so a reconnecting phone rebuilds
    /// only the live part: content and reasoning keep appending to the last row
    /// of their kind, exactly like the browser does.
    private func startStream() {
        api.startStream(onEvent: { e in
            switch e.kind {
            case .reasoning where events.last?.kind == .reasoning:
                events[events.count - 1].text += e.text
            case .content where events.last?.kind == .content:
                events[events.count - 1].text += e.text
            default:
                events.append(e)
            }
        }, onStart: {
            api.busy = true
            api.liveTokens = 0
        }, onEnd: {
            api.busy = false
        })
    }
}

// MARK: - rows

struct EventRow: View {
    let event: ChatEvent
    let api: BishopAPI
    @Binding var thinking: Bool
    @Binding var fullPicture: String?

    var body: some View {
        switch event.kind {
        case .user:
            Text(event.text).font(.system(size: 15, design: .monospaced))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(white: 0.17)).clipShape(RoundedRectangle(cornerRadius: 20))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .content:
            Text(event.text).font(.system(size: 15, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .reasoning:
            ThoughtBlock(text: event.text, open: $thinking)
        case .tool:
            Collapsible(summary: "› \(event.name) \(event.text)".prefix(120).description,
                        text: event.text, mono: true, tint: .yellow)
        case .toolResult:
            Collapsible(summary: "result", text: event.text, mono: true, tint: .gray)
        case .image:
            // Bound BOTH sides: a phone screenshot is 20:1 tall, so capping only
            // the height leaves a column of black stretching the whole row.
            AsyncImage(url: api.imageURL(event.imagePath)) { img in
                img.resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 320, maxHeight: 300, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .onTapGesture { fullPicture = event.imagePath }
            } placeholder: { ProgressView().tint(.gray).frame(width: 120, height: 120) }
                .frame(maxWidth: .infinity, alignment: .leading)
        case .info:
            Text(event.text).font(.system(size: 12, design: .monospaced)).foregroundStyle(.gray)
        case .error:
            Text("Error: \(event.text)").font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color(red: 1, green: 0.6, blue: 0.6))
                .padding(10).background(Color(red: 0.16, green: 0.08, blue: 0.09))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// Bishop's thoughts: dim, collapsed by default, one tap to read.
struct ThoughtBlock: View {
    let text: String
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
                    Text(open ? "thinking" : "thinking (\(text.count) chars)")
                        .font(.caption)
                }.foregroundStyle(.gray)
            }
            if open {
                Text(text).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(white: 0.55))
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().frame(width: 2).foregroundStyle(Color(white: 0.25)) }
            }
        }
    }
}

/// A tool call or its result: one dim line, the full text folded away.
struct Collapsible: View {
    let summary: String
    let text: String
    var mono = true
    var tint: Color = .gray
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { withAnimation { open.toggle() } } label: {
                Text(summary).font(.system(size: 12, design: mono ? .monospaced : .default))
                    .foregroundStyle(tint.opacity(0.8)).lineLimit(1)
            }
            if open, !text.isEmpty {
                Text(text).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.gray).textSelection(.enabled).padding(.leading, 10)
            }
        }
    }
}

struct PicturePath: Identifiable { let path: String; var id: String { path } }

struct PictureView: View {
    let path: String
    let api: BishopAPI
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AsyncImage(url: api.imageURL(path)) { $0.resizable().scaledToFit() }
                placeholder: { ProgressView() }
        }
        .onTapGesture { dismiss() }
    }
}

/// Shown when the Mac does not answer: the address and the token, nothing else.
struct ConnectBanner: View {
    @ObservedObject var api: BishopAPI
    @State private var host = ""
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not connected").font(.headline)
            Text("The Mac runs webui.py; the token is in ~/.bishop_web_token on it.")
                .font(.caption).foregroundStyle(.gray)
            TextField("192.168.2.12:8420", text: $host).textFieldStyle(.roundedBorder)
                .keyboardType(.URL).autocorrectionDisabled()
            TextField("token", text: $token).textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Button("Connect") {
                api.host = host; api.token = token
                Task { await api.connect() }
            }.buttonStyle(.borderedProminent)
            if !api.lastError.isEmpty {
                Text(api.lastError).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { host = api.host; token = api.token }
    }
}
