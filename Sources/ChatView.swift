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
    @State private var picking = false        // the session sheet

    var body: some View {
        // The bars hang off the SCROLL VIEW itself, via safeAreaBar - see
        // BarsOverTranscript. Inside a VStack the transcript stopped at their
        // edge, so nothing ever scrolled under the glass and the glass itself was
        // impossible to see; only a direct child can be pinned like this and get
        // the scroll edge effect (the frosted band under a bar).
        transcript
            .modifier(BarsOverTranscript(glass: glassBar, header: header, bottom: bottomBars))
            .background(Color.black)
            .preferredColorScheme(.dark)
            .task {
                // Keep trying until the Mac answers. iOS asks "find devices on your
                // local network" the first time the app touches 192.168.x.x, and the
                // FIRST request is refused while that prompt is on screen - a single
                // attempt would leave the app sitting on "Not connected" until it was
                // relaunched by hand.
                await reload()
                while !api.connected && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if Task.isCancelled { break }
                    await reload()
                }
            }
            .onAppear { startStream() }
            .sheet(item: Binding(get: { fullPicture.map(PicturePath.init) }, set: { fullPicture = $0?.path })) {
                PictureView(path: $0.path, api: api)
            }
            .sheet(isPresented: $picking) { sessionPicker }
    }

    // MARK: header

    /// True when the build toolchain and the running OS both know Liquid Glass.
    /// The COMPILER gate matters as much as the runtime one: `glassEffect` does
    /// not exist in the iOS 18 SDK, and a missing symbol is a compile error even
    /// inside an `#available` check. Xcode 26.2 and later ship Swift 6.2, so
    /// `compiler(>=6.2)` is exactly "the SDK has the glass APIs"; on Xcode 16 the
    /// whole glass branch is eliminated and never type-checked.
    private var glassBar: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    private var header: some View {
        HStack(spacing: 12) {
            // Same action as the title: it opens the session list, and a chevron
            // is what iOS 26 puts in that corner. No .glass button style here -
            // a bar already IS glass, and a glass button on glass reads as one
            // more bubble; the reference draws plain symbols on the bar.
            Button { picking = true } label: {
                Image(systemName: "chevron.left").font(.system(size: 22, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonBorderShape(.circle).barButton(false)

            // NOT a Menu: SwiftUI builds a Menu's label ONCE, so a picker showing
            // the session title kept showing the fallback from before the first
            // /api/state landed, however the data changed underneath it. The
            // chevron shows that it opens the list; the title is WHITE and at
            // title size, where .footnote grey was half the system's weight.
            Button { picking = true } label: {
                HStack(spacing: 6) {
                    Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonBorderShape(.capsule).barButton(glassBar)

            Button { Task { await newChat() } } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 20, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonBorderShape(.circle).barButton(glassBar)
        }
        .padding(.horizontal, 10).padding(.vertical, 2)
        .tint(glassBar ? .white : .gray)
    }

    /// Stats strip and composer, in one bar under the transcript. They used to be
    /// two more rows of the VStack; behind the glass they belong to the bottom
    /// edge effect instead.
    private var bottomBars: some View {
        VStack(spacing: 0) {
            if api.busy { liveBanner }
            statsStrip
            composer
        }
    }

    /// The session list: date + first words, the open one ticked.
    private var sessionPicker: some View {
        NavigationStack {
            List(api.sessions) { s in
                Button {
                    picking = false
                    Task { await open(s.id) }
                } label: {
                    HStack {
                        Text(s.title).font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.white)
                        Spacer()
                        if s.id == api.session { Image(systemName: "checkmark").foregroundStyle(.green) }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { picking = false } } }
        }
        .presentationDetents([.medium, .large])
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
                        EventRow(event: e, api: api, fullPicture: $fullPicture)
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
            // The composer is one glass pill holding a + on the left and the send
            // button on the right, with the text field sharing the same surface,
            // instead of a grey rounded box with loose circles on top of it.
            HStack(alignment: .bottom, spacing: 6) {
                PhotosPicker(selection: $picker, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(glassBar ? .white : .primary)
                        .background(glassBar ? AnyShapeStyle(.clear) : AnyShapeStyle(Color(white: 0.2)))
                        .clipShape(.circle)
                }
                TextField("Message Bishop", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 8)
                    .font(.system(size: 16, design: .monospaced))   // 16pt: iOS never zoom-scales
                // No .submitLabel/.onSubmit on purpose: a multiline TextField
                // with neither keeps the keyboard's return key as what it says -
                // a NEW LINE. Sending is the round button's job, so a reply can
                // be written in several lines without it flying off mid-thought.
                Button { api.busy ? stop() : send() } label: {
                    // One button, two jobs: a turn in flight turns it into the
                    // stop square, and pressing it ends the turn (the stream's
                    // 'end' then clears busy). While idle it is the send arrow.
                    Image(systemName: api.busy ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(glassBar ? AnyShapeStyle(.white) : AnyShapeStyle(.black))
                        .background(glassBar ? AnyShapeStyle(.clear) : AnyShapeStyle(.white))
                        .clipShape(.circle)
                }
                .disabled(!api.busy && draft.trimmingCharacters(in: .whitespaces).isEmpty && attachments.isEmpty)
            }
            .padding(8)
            .glassBar(glassBar, radius: 26, fallback: Color(white: 0.11))
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
        // The stream replays the turn, but the user's own line is not echoed
        // back mid-turn, so show it at once - same shape as the web page.
        let echo = paths.isEmpty ? text : text + (text.isEmpty ? "" : "\n") + "[picture]"
        events.append(ChatEvent(kind: .user, text: echo, imagePath: paths.first ?? ""))
        for p in paths { events.append(ChatEvent(kind: .image, imagePath: p)) }
        Task {
            if let problem = await api.send(text: text, paths: paths) {
                events.append(ChatEvent(kind: .info, text: problem))
            }
        }
    }

    private func stop() {
        // No local busy=false: the Mac ends the turn and the stream reports it,
        // so the button cannot flip back to "send" while the answer still runs.
        Task { await api.stopTurn() }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let path = await api.upload(data) {
                attachments.append((path, "photo"))
            }
        }
    }

    private func newChat() async {
        await api.newChat()
        events = []
        events = [ChatEvent(kind: .info, text: "New conversation.")]
    }

    private func open(_ id: String) async {
        await api.load(session: id)
        await reload()
    }

    private func reload() async {
        if !api.connected { await api.connect() }
        if let (list, sess) = try? await api.events(session: nil) {
            events = list
            api.session = sess
            await api.refresh()          // counters, session list, effort
        }
    }

    /// The stream replays the turn in flight, so a reconnecting phone rebuilds
    /// only the live part. The Mac does the grouping (reasoning tokens into one
    /// thought, content into one answer, a tool call starting a new phase), and
    /// each batch is MERGED onto the rows already on screen - so what arrives
    /// joins the bubble it belongs to instead of opening a new one.
    private func startStream() {
        api.startStream(onEvents: { batch in
            for row in batch { merge(row) }
        }, onStart: {
            api.busy = true
            api.liveTokens = 0
        }, onEnd: {
            api.busy = false
            closePhase(everything: true)   // a turn can end mid-thought, mid-answer
        })
    }

    /// One batch of streamed rows onto the transcript. A thought or an answer
    /// continues the last row of its kind if that is what it is; a tool call
    /// closes the open thought first, exactly like grow()/endThought() do in the
    /// browser. Tool arguments are re-sent with every delta, so the last one wins
    /// rather than being appended - otherwise every token doubles the line.
    private func merge(_ row: ChatEvent) {
        switch row.kind {
        case .answer where row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return                                   // invisible, as the page hides it
        case .thought, .answer:
            if let last = events.last, last.kind == row.kind, last.open {
                events[events.count - 1].text += row.text
                return
            }
            closePhase()                             // a new thought folds the old one
            var fresh = row
            fresh.open = true
            events.append(fresh)
        case .tool:
            closePhase()
            if let last = events.last, last.kind == .tool, last.name == row.name {
                events[events.count - 1].text = row.text
                return
            }
            events.append(row)
        default:
            closePhase()
            events.append(row)
        }
    }

    /// A phase boundary: a tool call, a result, or the end of the turn. The
    /// thought that was streaming folds into one "thought for Ns" line, and on a
    /// finished turn nothing keeps taking text - so the next turn cannot append
    /// to a bubble from the previous one.
    private func closePhase(everything: Bool = false) {
        for i in events.indices where events[i].open {
            if events[i].kind == .thought {
                events[i].open = false
                events[i].secs = max(1, Int(Date().timeIntervalSince(events[i].started)))
            } else if everything {
                events[i].open = false
            }
        }
    }
}

// MARK: - rows

struct EventRow: View {
    let event: ChatEvent
    let api: BishopAPI
    @Binding var fullPicture: String?

    var body: some View {
        switch event.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !event.text.isEmpty {
                    Text(event.text).font(.system(size: 15, design: .monospaced))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color(white: 0.17)).clipShape(RoundedRectangle(cornerRadius: 20))
                }
                if !event.imagePath.isEmpty {
                    AsyncImage(url: api.imageURL(event.imagePath)) { $0.resizable().scaledToFill() }
                        placeholder: { Color.gray }
                        .frame(height: 90).frame(maxWidth: 160).clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .answer:
            Text(event.text).font(.system(size: 15, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thought:
            ThoughtBlock(text: event.text, secs: event.secs)
        case .tool:
            // "> name {args}", one line, as the page shows it; the full call is
            // one tap away, pretty-printed.
            Collapsible(summary: "› \(event.name) \(event.text)".prefix(120).description,
                        text: Self.prettyJSON(event.text) ?? event.text,
                        mono: true, tint: .yellow)
        case .detail:
            Collapsible(summary: event.name, text: event.text, mono: true, tint: .gray)
        case .image:
            // Bound BOTH sides: a phone screenshot is 20:1 tall, so capping only
            // the height leaves a column of black stretching the whole row.
            VStack(alignment: .leading, spacing: 4) {
                AsyncImage(url: api.imageURL(event.imagePath)) { img in
                    img.resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 320, maxHeight: 300, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .onTapGesture { fullPicture = event.imagePath }
                } placeholder: { ProgressView().tint(.gray).frame(width: 120, height: 120) }
                if !event.name.isEmpty {
                    Text(event.name).font(.caption2).foregroundStyle(.gray)
                }
            }
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

    /// Tool arguments are a JSON string; a folded line is readable as one object
    /// per line, but showing raw JSON keeps it honest and copyable.
    static func prettyJSON(_ s: String) -> String? {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d),
              let p = try? JSONSerialization.data(withJSONObject: o,
                                                  options: [.prettyPrinted, .withoutEscapingSlashes]),
              let t = String(data: p, encoding: .utf8) else { return nil }
        return t
    }
}

/// Bishop's thoughts: dim, open while they stream, folded to "thought for Ns"
/// the moment the answer or a tool call begins - the web UI's details/summary,
/// one tap to read again.
struct ThoughtBlock: View {
    let text: String
    let secs: Int               // 0 while the thought is still running
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("▸").font(.caption2)      // the page's closed-fold marker
                    Text(secs > 0 ? "thought for \(secs)s" : "thinking...").font(.caption)
                }.foregroundStyle(.gray)
            }
            if show {
                Text(text).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(white: 0.55))
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().frame(width: 2).foregroundStyle(Color(white: 0.25)) }
            }
        }
    }

    private var show: Bool { secs == 0 || expanded }
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
            Text(summary).font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundStyle(tint.opacity(0.8)).lineLimit(1)
                .onTapGesture { withAnimation { open.toggle() } }
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
    @State private var host = BishopAPI.DEFAULT_HOST   // the address, so only the token is typed
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

// MARK: - Liquid Glass

/// The two bars on the scroll view's edges.
///
/// `safeAreaBar` is iOS 26 only, and it is what puts a bar ON TOP of scrolling
/// content: it insets the scroll view's safe area and adds the scroll edge effect
/// - the blur that makes the content visibly slide under the bar. Both gates are
/// needed, the compiler's (the symbol does not exist before Swift 6.2 / SDK 26,
/// and a missing symbol is an error even inside #available) and the OS one.
///
/// Before 26 there is no safeAreaBar, so the old layout is kept: a VStack with
/// the bars as ordinary rows.
private struct BarsOverTranscript<H: View, B: View>: ViewModifier {
    let glass: Bool
    let header: H
    let bottom: B

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if glass, #available(iOS 26.0, *) {
            content
                .safeAreaBar(edge: .top, spacing: 0) { header }
                .safeAreaBar(edge: .bottom, spacing: 0) { bottom }
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    /// iOS 17-18: the bars are rows of a VStack, the transcript a plain area.
    private func legacy(_ content: Content) -> some View {
        VStack(spacing: 0) {
            header
            content
            bottom
        }
    }
}

/// A button in a bar.
extension View {
    @ViewBuilder func barButton(_ glass: Bool) -> some View {
        if glass {
            #if compiler(>=6.2)
            // The compiler gate says the SDK HAS .glass; this one says the OS is
            // new enough to RUN it. Both are needed - dropping this check is a
            // compile error, not a fallback.
            if #available(iOS 26.0, *) {
                self.buttonStyle(.glass)
            } else {
                self.buttonStyle(.bordered)
            }
            #else
            self.buttonStyle(.bordered)
            #endif
        } else {
            self.buttonStyle(.borderless)
        }
    }

    /// The surface of a bar or the composer, on the view's whole frame including
    /// its padding - so pad first and call this last. A flat fill before iOS 26,
    /// Liquid Glass on it.
    func glassBar(_ glass: Bool, radius: CGFloat, fallback: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            // Under glass the fill has to go: the material is translucent, so a
            // dark slab behind it just greys it out.
            .background(glass ? Color.clear : fallback)
            .clipShape(shape)
            .modifier(GlassOn(glass: glass, shape: shape))
    }
}

private struct GlassOn: ViewModifier {
    let glass: Bool
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if glass, #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
