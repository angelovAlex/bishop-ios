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
    @State private var showLevels = false    // the effort chip's popover
    @State private var fullPicture: String?
    @State private var picking = false        // the session sheet
    @State private var mine: UUID?            // a just-sent message, to be put at the top
    @State private var content: CGFloat = 0   // how tall the transcript is
    @State private var viewport: CGFloat = 0  // ...and how much room it has
    @State private var following = true       // follow the newest text: the reader is at the bottom
    @State private var belowFold = false      // ...and the newest text is below the fold right now
    @State private var dragging = false       // a finger (or its momentum) is moving the transcript
    @State private var placing = false        // a just-sent message is on its way to the top
    @FocusState private var typing: Bool      // the composer's focus, so send() can drop the keyboard

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
        // Alex: "there is some not used space on left and right on ios client.
        // remove paddings so all width of screen will be used". The 10pt that
        // used to be here was a THIRD inset, on top of the chevron's own 17pt
        // circle and the title capsule's 14pt - its only job was to keep the
        // BAR's rounded glass edge off the display edge, and the bar is a
        // full-width band that has no rounded edge to keep in. The padding the
        // controls need is theirs (the circle's hit area, the capsule's inner
        // text), so nothing here is load-bearing; dropping it gives the row the
        // 20pt back for the title and lets the symbols sit at the system's own
        // bar margin.
        .padding(.horizontal, 0).padding(.vertical, 2)
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
        .padding(.horizontal, 6).padding(.bottom, 4)
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
                // No horizontal padding: the transcript runs edge to edge
                // (Alex's ask), because the rows that need a margin carry it
                // themselves - both SPEAKERS are inset on their own side, 14pt
                // each, so a bubble reads as the user's and an answer as
                // Bishop's, while a tool chip, a diff and the thought's grey
                // rule (drawn AT the left edge, the one place an inset shows as
                // a stripe of nothing) keep the full width.
                .padding(.horizontal, 0).padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { g in
                    Color.clear.onChange(of: g.size.height) { _, h in content = h }
                })
            }
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.size.height) { _, h in viewport = h }
            })
            .scrollDismissesKeyboard(.interactively)
            // Where the newest text is: below the fold, or already on screen?
            // Only this decides whether a scroll would be a scroll DOWN.
            .modifier(TranscriptScroll { below in
                belowFold = below
                // RE-ARM on the fact that matters: the transcript is at the
                // bottom, so that is the reader's place and following resumes.
                // Without this the flag could only ever be switched back on by a
                // gesture that happened to END exactly at the bottom, and one
                // that ended a moment early - or any moment where the geometry
                // read differently than the finger meant - left it off for good.
                // The symptom was Alex's: after the thinking block folded there
                // was no automatic scroll any more and he had to scroll by hand
                // for the rest of the session. Not while a finger is on it,
                // though: mid-drag the reader is deciding, not at rest.
                if !below, !dragging { following = true }
            } onPhase: { touching, settledByReader in
                // ONLY a finger, or the momentum it left behind, blocks following.
                // Not "not idle": this view's own scrolls report `.animating`, and
                // treating that as the reader meant that while text was arriving -
                // and the animation was being retargeted over and over - dragging
                // stayed true almost permanently and follow() returned early every
                // single time. That was "autoscroll does not work at all".
                dragging = touching
                // And only a reader's gesture may change the reader's place, once
                // it has come to rest.
                if settledByReader { following = !belowFold }
            })
            // What needs following, and the ORDER here is the whole trick: it is
            // the newest text ending up BELOW THE FOLD that is watched, not the
            // text arriving. On the text change alone the geometry still says
            // "the bottom is on screen" - it is the layout that follows that
            // pushes it down - so a text-driven scroll sees nothing to do, does
            // nothing, and the transcript freezes with the new line hidden. The
            // geometry change is the moment there is really something to fix. It
            // is also, by construction, only ever a DOWNWARD fix: a block that
            // shrinks (a thought rewritten as a shorter paragraph) moves the
            // bottom UP, belowFold goes false, and nothing is scrolled at all -
            // which is exactly the stillness Alex asked for.
            .onChange(of: belowFold) { _, _ in follow(proxy) }
            .onChange(of: events.count) { _, _ in follow(proxy) }
            .onChange(of: events.last?.text) { _, _ in follow(proxy) }
            // The keyboard is the third reason the newest line can end up hidden,
            // and the one that was reported: the composer takes the room the live
            // thinking block was using, so the block slides under the fold with no
            // text having changed.
            .onChange(of: viewport) { _, _ in follow(proxy) }
        }
    }

    /// Bring the newest text back into view - DOWNWARDS ONLY, and only while the
    /// reader is at the newest text. Both halves are load-bearing:
    ///
    /// `following` is off the moment the reader scrolls away from the newest line
    /// (see TranscriptScroll, which listens to the scroll phase), so a turn in
    /// flight cannot drag them back to the bottom, and it comes back on when they
    /// return there.
    ///
    /// The `below` test is what makes this direction-only. Reaching for the
    /// bottom would also "fix" the case where the newest line is ABOVE the fold,
    /// which is what a shrinking block does - and pulling the chat up there is
    /// exactly the jump Alex rejected automatic binding for. If the bottom is
    /// already on screen there is nothing to do, so the block simply keeps its
    /// held height and the chat sits perfectly still.
    private func follow(_ proxy: ScrollViewProxy) {
        // A send is the one scroll wanted for its own sake: the user's message
        // goes to the TOP so the answer has the screen below it.
        if let id = mine {
            mine = nil
            following = true            // ...and then the answer is to be followed
            // `placing` until the jump has landed, or the geometry it produces -
            // the message at the top, everything else below the fold - would read
            // as "the newest line is hidden" and be undone on the next line.
            placing = true
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(id, anchor: .top)
            } completion: {
                placing = false
                // The jump is done, so the ordinary rule applies again - and it
                // has to be run here, because the send itself is not a trigger:
                // until the first token arrives nothing else would pull a
                // too-long transcript down to the newest line.
                DispatchQueue.main.async { follow(proxy) }
            }
            return
        }
        guard following, !dragging, !placing else { return }
        // One turn later, because these values come from layout and this runs
        // inside the change that produced them: on a text change they still
        // describe the frame BEFORE that text was laid out. Measured: a stale
        // content height read 1477 where the true one was 1290.
        DispatchQueue.main.async {
            guard following, !dragging, !placing else { return }
            // Also the direction test, and it reads the way it is written:
            // belowFold true MEANS the newest line is under the bottom edge, so
            // that is the case to fix. (Written the other way round once, as
            // `guard !belowFold`, which scrolled only when there was nothing to
            // scroll to and so never followed anything at all.)
            if canMeasure { guard belowFold else { return } }
            else { guard content > viewport + 1 else { return } }
            // A short LINEAR animation, not none and not a spring: text arrives
            // continuously, so this is retargeted before it finishes and the
            // result is a steady glide. A snap reads as a jump (Alex: "it just
            // jumps to new line without animation") and a spring overshoots and
            // fights the next one.
            withAnimation(.linear(duration: 0.12)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Does the OS report the transcript's scroll geometry - and therefore let
    /// the follow be direction-aware? See TranscriptScroll. Without it (iOS 17,
    /// or a build that cannot see the API) the blunter height test stands in,
    /// which cannot tell "below the fold" from "above it".
    private var canMeasure: Bool {
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) { return true }
        #endif
        return false
    }

    // MARK: counters (one dim line, tap for the report)

    /// Two lines, the last turn and the whole session, unlabelled in the same
    /// `in / c / bill / out / cost` shape - Alex's wording: "Don't write 'last'
    /// and 'session'. 'cache' change to 'c'". They are told apart by weight
    /// instead: the last turn is the live one, so it keeps full contrast while
    /// the session line below it is dimmed. `in` is the PROMPT at its true size
    /// (bill + c), which is also the context in play for the last turn; `bill`
    /// is the only part that costs money. Calls and the lifetime total live in
    /// the fold.
    ///
    /// The pair used to be `in 75k cache 1.56m`, which Alex rightly reported as
    /// impossible ("How can it be that cache is 1.56m?"): `in` was the BILLED
    /// prompt, `cache` the cumulative gross, two bases on one line. Now in =
    /// bill + c on screen, so the line can be added up by eye.
    private var statsStrip: some View {
        Button { withAnimation { showStats.toggle() } } label: {
            VStack(alignment: .leading, spacing: 2) {
                if let u = api.usage {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(counters(u.lastInput, u.lastCached, u.lastBilled, u.lastOutput, u.lastCost))
                            Text(counters(u.grossInput, u.cached, u.billedInput, u.output, u.sessionCost))
                                .foregroundStyle(.gray.opacity(0.55))
                        }
                        Spacer()
                        Image(systemName: showStats ? "chevron.up" : "chevron.right").font(.caption2)
                    }
                    .lineLimit(1).minimumScaleFactor(0.7)
                    if showStats {
                        Text("calls \(u.calls)   lifetime \(u.totalCost)")
                            .foregroundStyle(.gray.opacity(0.75))
                    }
                } else {
                    Text("no call yet").bold(); Spacer()
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.gray)
            .padding(.horizontal, 6).padding(.bottom, 4)
        }
        .buttonStyle(.plain)
    }

    /// One stats line: in = bill + c, so the reader can check the split by eye.
    private func counters(_ prompt: Int, _ cached: Int, _ billed: Int, _ out: Int, _ cost: String) -> String {
        "in \(short(prompt)) c \(short(cached)) bill \(short(billed)) out \(short(out)) \(cost)"
    }

    private func short(_ v: Int) -> String {
        if v < 1000 { return "\(v)" }
        if v < 1_000_000 { return String(format: "%.1fk", Double(v) / 1000) }
        return String(format: "%.2fM", Double(v) / 1_000_000)
    }

    // MARK: reasoning effort (the chip in the composer's option row)

    /// How hard Bishop thinks before answering - the same POST /api/effort the
    /// page's <select> calls. The row it used to be (a segmented picker one line
    /// above the composer) is gone: Alex wants the composer laid out like the
    /// reference - text field on top, and a row of options UNDER it between the
    /// + and the send arrow, with this as the first option. Hence a chip the
    /// width of its own word, in a popover rather than a full-width control.
    ///
    /// Hidden until /api/state has sent the levels: a chip with no level would
    /// either be empty or a guess.
    private var effortChip: some View {
        Group {
            if !api.levels.isEmpty {
                Button { showLevels = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "brain").font(.system(size: 12, weight: .semibold))
                        Text(api.effort).font(.system(size: 13, design: .monospaced))
                    }
                    .foregroundStyle(glassBar ? .white : .primary)
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(glassBar ? AnyShapeStyle(.clear) : AnyShapeStyle(Color(white: 0.2)))
                    .clipShape(.capsule)
                }
                .popover(isPresented: $showLevels) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(api.levels, id: \.self) { level in
                            Button {
                                showLevels = false
                                Task { await api.setEffort(level) }
                            } label: {
                                HStack {
                                    Text(level).font(.system(size: 14, design: .monospaced))
                                    Spacer(minLength: 24)
                                    // The tick marks the level in force; without
                                    // it the list reads as commands rather than
                                    // as a state.
                                    if level == api.effort { Image(systemName: "checkmark") }
                                }
                                .padding(.vertical, 9).padding(.horizontal, 14)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    .presentationCompactAdaptation(.popover)
                }
                // The level is read when a turn starts, so changing it mid-turn
                // would do nothing anyway.
                .disabled(api.busy)
            }
        }
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
                    }.padding(.horizontal, 4)
                }
            }
            // The composer is one glass pill: the text field takes the top, and
            // a row of controls sits under it - + on the left, the options in
            // the middle, the send arrow on the right. That is the reference
            // layout (Alex: "when I type it types above plus and send button,
            // and between plus and send we will have more options"): the field
            // gets the full width and grows upward, while the controls keep one
            // row each, instead of the field being squeezed between the two
            // circles and the + riding up with it as the text wrapped.
            VStack(spacing: 4) {
                TextField("Message Bishop", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 8)
                    .font(.system(size: 16, design: .monospaced))   // 16pt: iOS never zoom-scales
                    .focused($typing)
                    // No submitLabel/onSubmit on purpose: the Return key must
                    // insert a newline (multiline field, `axis: .vertical`),
                    // and the round arrow on the right is what sends.
                HStack(spacing: 8) {
                    PhotosPicker(selection: $picker, maxSelectionCount: 4, matching: .images) {
                        Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(glassBar ? .white : .primary)
                            .background(glassBar ? AnyShapeStyle(.clear) : AnyShapeStyle(Color(white: 0.2)))
                            .clipShape(.circle)
                    }
                    effortChip
                    Spacer(minLength: 4)
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
            }
            .padding(8)
            .glassBar(glassBar, radius: 26, fallback: Color(white: 0.11))
            // 4, not 10: the pill now stretches nearly the whole width, which is
            // the room that went to waste beside it. Two points are kept so the
            // glass's rounded edge and the screen's edge do not read as one line.
            .padding(.horizontal, 4)
        }
        .padding(.bottom, 6)
        .onChange(of: picker) { _, items in Task { await addPhotos(items); picker = [] } }
        // Return key inserts a newline - the field is multiline and there is no
        // submitLabel/onSubmit on it - so the round arrow button is the only way
        // to send. Pasted multi-line text therefore survives intact.
    }

    // MARK: actions

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = attachments.map(\.path)
        guard !text.isEmpty || !paths.isEmpty else { return }
        draft = ""
        attachments = []
        typing = false          // the keyboard goes down and gives the answer the screen
        // The stream replays the turn, but the user's own line is not echoed
        // back mid-turn, so show it at once - same shape as the web page.
        let echo = paths.isEmpty ? text : text + (text.isEmpty ? "" : "\n") + "[picture]"
        let sent = ChatEvent(kind: .user, text: echo, imagePath: paths.first ?? "")
        events.append(sent)
        mine = sent.id          // ...at the TOP, so the transcript fills what is left
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
    ///
    /// The server does NOT say that a replay is a replay: it rebuilds the turn in
    /// flight from its 'start' event and sends it to every client identically, so
    /// a client that just connected sees a thought already in progress. `live`
    /// (which carries nothing but counters) is the one signal reserved for a turn
    /// actually running, and the server emits the first one 0.15 s after the
    /// first reasoning token - so its arrival is when the thought on screen can
    /// honestly start being timed.
    private func startStream() {
        api.startStream(onEvents: { batch in
            for row in batch { merge(row) }
        }, onLive: { markWatched() }, onStart: {
            api.busy = true
            api.liveTokens = 0
        }, onEnd: {
            api.busy = false
            closePhase(everything: true)   // a turn can end mid-thought, mid-answer
        })
    }

    /// A recall goes in FRONT of the turn it belongs to, not at the bottom of the
    /// transcript. A phase continues only while it is the LAST row - that is how
    /// a streamed thought or answer grows - so appending a recall in the middle
    /// of one would slice the thought in two, and a step that happened to open
    /// with reasoning would leave that half stranded below the new row.
    ///
    /// The turn is the run of OPEN rows at the end: live, that is the thought or
    /// the answer being written. In a replay every row of a finished hop is
    /// closed, so the recall lands after them - which is where it belongs anyway,
    /// with the rest of that hop.
    private func insertRecall(_ row: ChatEvent) {
        var at = events.count
        while at > 0 && events[at - 1].open { at -= 1 }
        events.insert(row, at: at)
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
        case .recall:
            insertRecall(row)
        case .tool:
            closePhase()
            // Arguments are re-sent as they stream, so a call already on screen
            // is UPDATED in place: the row stays one, and its name is what
            // identifies it when the stream carries no call id.
            if let i = toolRow(for: row) {
                events[i].text = row.text
                if row.view != nil { events[i].view = row.view }
                return
            }
            events.append(row)
        case .result:
            closePhase()
            // A result joins the call above it (one row per call). With no call
            // to join it keeps its own row, folded as it always was.
            guard let i = toolRow(for: nil) else { events.append(row); return }
            // The verdict was already read off this event while it was decoded,
            // when its call was in the same batch; a result that arrived alone
            // (the call long drawn) is judged here, by the same rule.
            let good = row.ok ?? Self.succeeded(row)
            events[i].ok = good
            // A good edit said what happened in its chip; a failure says it here
            // and nowhere else, so it is kept whatever the view claims.
            events[i].result = good && ToolView.speaksForItself(row.view) ? "" : row.text
            // The call's view DESCRIBES the row (an edit's chip and diff), the
            // result's only reports ("ok", true): never overwrite the former -
            // except for a read, whose content only exists in the result.
            events[i].view = ToolView.describedBy(events[i].view, row.view)
        default:
            closePhase()
            events.append(row)
        }
    }

    /// The row a tool event belongs to. A CALL continues the row just drawn if
    /// it is the same call - by the provider's id when both have one, otherwise
    /// by name, since the arguments are re-sent as they stream in. A RESULT
    /// belongs to the call above it, which is either the call this app just drew
    /// or, in a stored session replayed as a flat list, the one before it.
    private func toolRow(for row: ChatEvent?) -> Int? {
        guard let last = events.indices.last, events[last].kind == .tool else { return nil }
        guard let row else { return last }
        if !row.callId.isEmpty && !events[last].callId.isEmpty {
            return row.callId == events[last].callId ? last : nil
        }
        return events[last].name == row.name ? last : nil
    }

    /// Did a tool result succeed? The event says it in two places and BOTH are
    /// needed: the Mac's view, when the tool has one, and the plain text, which
    /// is all a tool without a view has. A result that reports neither ("OK: 7
    /// tests passed") has succeeded - so the test is for the two ways it can say
    /// no, and everything else is a yes. Reading it as "yes only on a known ok"
    /// was how a failed call came back wearing a tick: the server's view for a
    /// plain tool is {} and the text was the only evidence there was.
    static func succeeded(_ e: ChatEvent) -> Bool {
        if e.view?.ok == false { return false }
        let t = e.text.trimmingCharacters(in: .whitespaces)
        return !t.hasPrefix("Error") && !t.hasPrefix("Not run")
    }

    /// The turn really is running on the Mac now (the stream's `live` counters),
    /// so the thought it is writing may be timed from here. Everything before
    /// this arrived as a replay of words already written, which is why showing up
    /// in the middle of a thought leaves it unwatched - and, when it folds, with
    /// no duration rather than a fabricated "1s".
    private func markWatched() {
        for i in events.indices where events[i].open && events[i].kind == .thought && !events[i].watched {
            events[i].started = Date()
            events[i].watched = true
        }
    }

    /// A phase boundary: a tool call, a result, or the end of the turn. The
    /// thought that was streaming folds into one dim line (with its duration, if
    /// this app was watching when it started), and on a finished turn nothing
    /// keeps taking text - so the next turn cannot append to a bubble from the
    /// previous one.
    private func closePhase(everything: Bool = false) {
        for i in events.indices where events[i].open {
            if events[i].kind == .thought {
                events[i].open = false
                // A duration needs a clock that started while the thought was
                // still being written (markWatched) and at least two seconds of
                // it; anything else - a thought that arrived folded with a
                // reopened session, or one this app caught mid-flight - says
                // "thought" instead of inventing a number. Timing it from the
                // moment its rows were decoded is what made every line read
                // "thought for 1s".
                if events[i].watched {
                    let secs = Int(Date().timeIntervalSince(events[i].started))
                    if secs >= 2 { events[i].secs = secs }
                }
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
            // Alex: "for my bubbles keep padding at left so we see that it is
            // from my side". Then, on the first attempt: "my bubble now is in
            // the middle because you made padding from both sides". Both are
            // right, and the middle is what a LEADING-aligned full-width bubble
            // looks like: its text is long enough to fill the row, so it ends up
            // with a gap on each side and belongs to nobody.
            //
            // So the row keeps the side it always had - TRAILING - and the 14pt
            // at the leading edge is a CAP, not an alignment: a short "ok" still
            // hugs the right edge, a long paragraph stops 14pt short of the left
            // one. The two speakers are still inset from each other's side only
            // (the answer takes 14 at the trailing edge, see below), which is
            // what says who is talking; the bubble's own 14 inner padding is what
            // keeps its text off the screen's right edge.
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
            .padding(.leading, 14)
        case .answer:
            Text(event.text).font(.system(size: 15, design: .monospaced))
                .textSelection(.enabled)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thought:
            ThoughtBlock(text: event.text, secs: event.secs, running: event.open)
        case .recall:
            RecallRow(text: event.text)
        case .tool:
            // One row per call: the call is the summary, the result is inside the
            // fold. An EDIT is drawn the way VS Code draws one, and a READ of a
            // file and a SEARCH of the tree wear the SAME chip - the thing with
            // its blue glyph (a file, a magnifier) and, for a read, the lines it
            // covered, for a search, how much it found. The edit opens on arrival
            // (the diff is the point and is written down nowhere else); the read
            // and the search are born folded, so a whole file - or 300 hits -
            // stays one tap away. The full call stays one tap further in.
            if let v = event.view, ToolView.describes(v) {
                EditChip(view: v, raw: event.text, result: event.ok == false ? event.result : "",
                         ok: event.ok)
            } else {
                ToolRow(event: event)
            }
        case .result:
            // A tool result with no call above it to join. Folded, as before.
            if let v = event.view, v.kind == "ok", v.ok { EmptyView() }
            else if let v = event.view, ToolView.describes(v) {
                EditChip(view: v, raw: "", result: event.ok == false ? event.text : "")
            } else { Collapsible(summary: event.name, text: event.text, mono: true, tint: .gray) }
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

/// A plain tool call and its result: ONE row. The call is the line; the fold
/// holds the whole call, pretty-printed, and what the tool answered. It is born
/// looking like a call ("name {args}") because that is what has happened so far,
/// and gains a green tick (or a red cross) the moment the tool answers.
///
/// A failure opens the fold on its own: the reason ("Error: no such file") is
/// the only place it is written down, and an unasked tap is a small price for
/// never hiding why something did not run.
struct ToolRow: View {
    let event: ChatEvent
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 5) {
                Text(open ? "\u{25BE}" : "\u{25B8}").font(.system(size: 10)).foregroundStyle(.gray)
                Text(event.name + " " + event.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.yellow.opacity(0.8)).lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let ok = event.ok {
                    Text(ok ? "\u{2713}" : "\u{2717}")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ok ? ToolRow.green : ToolRow.red)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } }
            if open, !fold.isEmpty {
                Text(fold).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.gray).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A failure opens itself: its reason is written down nowhere else. Both
        // halves are needed - onAppear for a session replayed from disk (the row
        // is built with ok already set, so nothing ever CHANGES), onChange for
        // the live stream, where the row is born without it.
        .onAppear { if event.ok == false { open = true } }
        .onChange(of: event.ok) { _, now in if now == false { open = true } }
    }

    /// What the fold holds: the call as it was made, then the answer. Raw JSON is
    /// kept alongside the pretty version because a fold is also for copying.
    private var fold: String {
        var s = ""
        if !event.text.isEmpty { s = "call\n" + (EventRow.prettyJSON(event.text) ?? event.text) }
        if !event.result.isEmpty { s += (s.isEmpty ? "" : "\n\n") + "result\n" + event.result }
        return s
    }

    private static let green = Color(red: 0.4, green: 0.85, blue: 0.5)
    private static let red = Color(red: 1.0, green: 0.45, blue: 0.45)
}

/// Bishop's thoughts: dim, and folded the moment the answer or a tool call begins
/// - the web UI's details/summary, one tap to read again.
///
/// The label is the state, in three words: "thinking..." while the thought runs,
/// "thought" when it is over but no duration was measured (a session read back
/// from disk carries no timings, and the app may have caught a turn already in
/// flight), "thought for Ns" when this app clocked it.
struct ThoughtBlock: View {
    let text: String
    let secs: Int               // 0 while the thought is still running
    let running: Bool           // the turn is being written right now
    @State private var expanded = false
    /// The tallest this block has ever been. It only ever goes up, and the block
    /// never renders shorter than it - see body.
    @State private var held: CGFloat = 0

    /// Past this the block stops growing and scrolls inside itself, so a long
    /// paragraph cannot take the screen away from the transcript.
    private static let maxBody: CGFloat = 180

    private var label: String {
        if running { return "thinking..." }
        return secs > 0 ? "thought for \(secs)s" : "thought"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("▸").font(.caption2)      // the page's closed-fold marker
                    Text(label).font(.caption)
                }.foregroundStyle(.gray)
            }
            if show {
                if expanded { whole } else { liveParagraph }
            }
        }
    }

    /// While a thought is being written, only its LAST PARAGRAPH is on screen -
    /// the line Bishop is on now, the way Apollo streams a reasoning summary. The
    /// paragraph is REPLACED as soon as a blank line follows it, so the block
    /// stays one paragraph tall instead of growing a wall of text. Open it (a tap)
    /// and the whole thought is there, capped and scrollable.
    ///
    /// A FOLDED thought shows no body at all, just its one-line label: it is
    /// over, its reasoning is noise by then, and a finished thought that kept its
    /// text would leave a screen of grey behind every tool call - which is what
    /// the web page's collapsed details element avoids.
    ///
    /// Empty text while running is legitimate and shows NOTHING: a thought that
    /// has sent only "#" or a blank line so far has no paragraph yet, and an
    /// empty line under the label would just push the transcript around.
    private var whole: some View { clipped { Text(text) } }

    /// The paragraph being written, held at its own bottom as it grows: past
    /// maxBody the block keeps its height and the newest line is the one in
    /// sight, which is the whole point of showing only the live paragraph. Each
    /// paragraph starts at the top instead of at the offset of the one it
    /// replaced.
    private var liveParagraph: some View {
        ScrollViewReader { proxy in
            clipped { Text(lastParagraph) }
                .onChange(of: lastParagraph) { _, _ in
                    proxy.scrollTo("tail", anchor: .bottom)
                }
        }
    }

    private func clipped<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content()
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(white: 0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id("tail")
            }
            // Measured on the INNER stack, which the ScrollView lays out at its
            // own natural height: were this on the ScrollView instead, the frame
            // below would be proposed to it and the reader would just measure
            // back the height it had been handed. Peaks only, so a paragraph
            // replaced by a shorter one does not make the block shrink.
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.size.height) { _, h in
                    let capped = min(h, Self.maxBody)
                    if capped > held { held = capped }
                }
            })
        }
        // The HEIGHT half of "scroll down only", and the one that actually
        // matters: while a thought runs it is rewritten paragraph by paragraph,
        // and a paragraph is any number of lines, so the block's natural height
        // breathes. Every one of those changes moves whatever is on screen -
        // which is what Alex kept seeing, and no scroll rule can undo it. Holding
        // the tallest height the thought has reached makes the block a fixed
        // panel: it only ever grows, so the only thing left to do with the
        // transcript is follow the new line DOWN.
        .frame(height: held > 0 ? held : nil)
        // Shorter than the cap means there is nothing to scroll: no bounce, no
        // rubber band, the block simply sits there at its natural height.
        .scrollBounceBehavior(.basedOnSize)
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Rectangle().frame(width: 2).foregroundStyle(Color(white: 0.25)) }
    }

    private var show: Bool { expanded || (running && !lastParagraph.isEmpty) }

    /// Everything after the last blank line, which is what the model has just
    /// written. Two traps, both from the fact that this runs on half a streamed
    /// thought: the trailing newlines already received for the paragraph that has
    /// not started yet must be dropped (or the block would render EMPTY the
    /// moment the model ends a line - the text ends in "\n"), and a paragraph
    /// that is blank on the inside is not a paragraph. Splitting on `.newlines`
    /// rather than on the two-character string "\n\n" also makes CRLF one
    /// separator instead of two, which needs no special case at all.
    private var lastParagraph: String {
        let lines = text.components(separatedBy: .newlines)
        func blank(_ i: Int) -> Bool { lines[i].trimmingCharacters(in: .whitespaces).isEmpty }
        var end = lines.count
        while end > 0 && blank(end - 1) { end -= 1 }        // the not-yet-started tail
        var start = end
        while start > 0 && !blank(start - 1) { start -= 1 }  // back to the blank line before it
        return lines[start..<end].joined(separator: "\n")
    }
}


/// The wheel a COMMAND's row wears while it runs, in the place every other chip
/// puts its glyph - a standard spinning wheel, which is what Alex asked for there.
///
/// It is drawn rather than borrowed from ProgressView because a ProgressView
/// carries a system control's size and tint and cannot be asked to sit exactly
/// where a file glyph would. The ring spins on a REPEATING animation started in
/// onAppear with withAnimation: `.animation(_:value:)` on a state set in the same
/// pass as the insertion is COALESCED and the ring then never moves at all -
/// verified on the simulator by diffing two frames of a running row (0 pixels
/// moved), and it is the whole point of the row.
struct ChipWheel: View {
    @State private var on = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(Color(white: 0.62), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(on ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
                    on = true
                }
            }
    }
}

/// A file edit, a file read or a search, drawn the way VS Code writes it in a
/// transcript: the thing in a chip - its glyph in blue, its name, what this call
/// did to it - and the content under it. A read says ", lines 1 to 19" after the
/// chip, a search ", 2 files", an edit says nothing there because its counts are
/// inside it. All three kinds are this one body, because one view means one
/// place to fix.
struct EditChip: View {
    let view: ToolView
    let raw: String
    var result = ""                     // a failure's own words, if it had any
    var ok: Bool? = nil                 // nil until the result arrived
    /// nil until the user taps: a READ and a SEARCH are born folded, an EDIT (a
    /// diff, and the only place those lines are written down) is born open. Alex
    /// asked for the read to stop dumping a whole file into the transcript on
    /// arrival - and a search is the same case, at 300 hits.
    @State private var tapped: Bool? = nil
    @State private var showCall = false

    private var read: Bool { view.kind == "read" }
    private var search: Bool { view.kind == "search" }
    /// A COMMAND: the box holds the command, the verdict is its exit code and the
    /// duration rides inside the box (it is the figure for the command it timed).
    /// It is the only chip drawn while it is STILL HAPPENING - the call arrives
    /// before the tool has answered, and that is what the wheel is for.
    private var shell: Bool { view.kind == "shell" }
    private var open: Bool { tapped ?? !(read || search || shell) }
    private func toggle() { withAnimation(.easeInOut(duration: 0.15)) { tapped = !open } }
    /// A read carries the span of lines it covered, a search how much it found;
    /// an edit's counts are already in the chip, so it says nothing out here. A
    /// command's duration is in its box, so a comma out here would separate two
    /// things that belong together.
    private var span: String {
        (read || search) && !view.span.isEmpty ? ", \(view.span)" : ""
    }
    /// What the chip says happened. A command's is the only one that changes by
    /// itself: its call has run nothing yet, so it says Running until the exit
    /// code arrives - the wheel beside it is that same fact, drawn.
    private var label: String {
        if !view.subtitle.isEmpty { return view.subtitle }
        return read ? "Read" : search ? "Found" : shell ? "Running" : "Edited"
    }
    /// A command's own words are already in view.note (the tool's reason for
    /// killing it) and its output is the rows, so the raw result text would say
    /// the same thing twice. Every other chip has nowhere else to put it.
    private var shownResult: String { shell ? "" : result }
    /// An edit counts +/- in green and red; a read's or a search's chip holds only
    /// the name, so a read of ONE line needs its span out there to say anything.
    private var counts: Text? {
        if read || search || shell { return nil }    // only an edit counts lines
        guard view.added > 0 || view.removed > 0 else { return nil }
        let plus = view.added > 0 ? Text("+\(view.added)").foregroundStyle(EditChip.green)
                                  : Text("")
        let gap = view.added > 0 && view.removed > 0 ? Text(" ") : Text("")
        let minus = view.removed > 0 ? Text("-\(view.removed)").foregroundStyle(EditChip.red)
                                     : Text("")
        return plus + gap + minus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // The tick leads, the way the reference draws it: tick, label,
                // then the file. A chip starts with its tick already in place
                // (the row appears after the tool ran or is replaying a finished
                // turn), and mark() rewrites it if the result says otherwise.
                //
                // A COMMAND wears the WHEEL here until its exit code arrives: it
                // is the only row that exists before it has an answer, so the
                // verdict and the waiting are ONE slot - otherwise the check would
                // appear somewhere the wheel never was, and the row would jump
                // sideways the moment the command finished. The slot is a fixed
                // width for the same reason.
                if shell {
                    Group {
                        if let ok {
                            Text(ok ? "\u{2713}" : "\u{2717}")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ok ? EditChip.green : EditChip.red)
                        } else {
                            ChipWheel()
                        }
                    }
                    .frame(width: 12, alignment: .leading)
                } else if let ok {
                    Text(ok ? "\u{2713}" : "\u{2717}")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ok ? EditChip.green : EditChip.red)
                }
                Text(label).foregroundStyle(Color(white: 0.62))
                // The box and the span are ONE group, so the ", lines 1 to 19"
                // hugs the box instead of floating a stack-spacing away from it.
                HStack(spacing: 0) {
                    HStack(spacing: 5) {
                        // The glyph in its blue: a pencil for an edit, a FILE for
                        // a read - which is what says "this was read, not
                        // changed" at a glance - and a MAGNIFIER for a search,
                        // which looked instead of finding what it named. It was
                        // briefly a language badge (TS, PY) and Alex asked for
                        // the glyph back.
                        //
                        // A command's glyph slot is left empty: its wheel and then its
                        // verdict are in the lead slot, so a second mark inside
                        // the box would be the same thing said twice. Every other
                        // chip's glyph says WHAT was acted on (a file, a
                        // magnifier), which is why this is the one exception.
                        if !shell {
                            Image(systemName: search ? "magnifyingglass"
                                                     : read ? "doc.text" : "pencil.tip.crop.circle")
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(EditChip.blue)
                        }
                        Text(view.title).foregroundStyle(shell ? EditChip.warm : Color(white: 0.92))
                            .lineLimit(1)
                        if !shell { counts }
                        // A command's duration rides IN its box, right after the
                        // command it timed - the same place the browser draws it
                        // - so the two figures cannot be separated by a row that
                        // ran out of width.
                        if shell && !view.span.isEmpty {
                            Text(view.span).foregroundStyle(Color(white: 0.5))
                                .padding(.leading, 8)
                        }
                        // The command gives way when the row runs out of width,
                        // never the duration: a long command used to push "9.63s"
                        // off the right edge of a phone.
                    }
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color(white: 0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(white: 0.2)))
                    .onTapGesture { toggle() }
                    if !span.isEmpty {
                        Text(span).font(.system(size: 12)).foregroundStyle(Color(white: 0.42))
                    }
                }
            }
            // What a search did NOT cover ("hidden folders skipped; result limit
            // reached"), or why a command was killed. It is outside the fold on
            // purpose: a list that stopped early reads as the whole tree unless
            // this is in sight, and the fold is exactly where a reader would not
            // look. A command's is a FAILURE, so it keeps the red.
            if !view.note.isEmpty {
                Text(view.note).font(.system(size: 10.5))
                    .foregroundStyle(shell && ok == false ? EditChip.red.opacity(0.9)
                                                          : Color(white: 0.45))
            }
            if open, !view.rows.isEmpty || !shownResult.isEmpty {
                if !view.rows.isEmpty {
                    // Scrolls sideways rather than wrapping: a wrapped line pushes
                    // its continuation under the +/- marker, and the marker is what
                    // the eye follows down the block.
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(view.rows) { r in
                                Text(r.tag == "gap" ? "" : Self.marked(r))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(r.tag == "eq" ? Color(white: 0.55) : EditChip.fg(r.tag))
                                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 4).padding(.vertical, 0.5)
                                    .background(EditChip.bg(r.tag))
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(white: 0.16)))
                    .onTapGesture { showCall.toggle() }   // a second tap shows how it was called
                    if showCall {
                        Text(EventRow.prettyJSON(raw) ?? raw)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.gray).padding(.leading, 4)
                    }
                }
                // A FAILED edit or read has one thing to say that the chip cannot:
                // the tool's own message ("old_text not found in X", "no such
                // file"). It goes in the fold and is never folded away by us.
                if !shownResult.isEmpty {
                    Text(shownResult).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(EditChip.red.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The +/- marker in place of a line-number column: the column is a fifth of a
    /// phone's width, and the marker is what the eye actually follows. A search
    /// hit is neither added nor removed, so it carries no marker at all.
    private static func marked(_ r: ToolView.Row) -> String {
        r.tag == "hit" ? r.text : (r.tag == "add" ? "+ " : r.tag == "del" ? "- " : "  ") + r.text
    }
    private static let blue = Color(red: 0.35, green: 0.65, blue: 1.0)
    /// What a COMMAND's box is written in: the warm ink of a terminal prompt, the
    /// way the reference (VS Code's own transcript) paints it. A command is the
    /// one chip whose content is something someone TYPED, so it is the one that
    /// gets to look like shell.
    private static let warm = Color(red: 0.91, green: 0.75, blue: 0.49)
    private static let green = Color(red: 0.4, green: 0.85, blue: 0.5)
    private static let red = Color(red: 1.0, green: 0.45, blue: 0.45)
    private static func fg(_ tag: String) -> Color {
        // A hit is the whole point of its row, so it is the brightest thing in it.
        tag == "hit" ? Color(white: 0.72) : tag == "add" ? green : tag == "del" ? red : .gray
    }
    private static func bg(_ tag: String) -> Color {
        switch tag {
        case "add": return green.opacity(0.12)
        case "del": return red.opacity(0.12)
        default: return .clear
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

/// The memory notes this turn was answered on, as one folded line: what recall
/// pasted in front of the message, kept openable so it can be read and checked
/// rather than trusted. It is neither side of the conversation - the model read
/// it, nobody typed it - so it is a quiet grey row, not a bubble, and it is born
/// folded because the block can be a few kilobytes.
///
/// The label is the block's OWN lead-in ("recall: 3 notes for 'who is olivia'"),
/// which also names the query it was fetched for - so the line, the fold and the
/// request cannot disagree, and a weak match says so in the same place.
struct RecallRow: View {
    let text: String
    @State private var open = false

    private var label: String {
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        return trimmed.isEmpty ? "recall" : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "book.closed").font(.system(size: 10))
                Text(label).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            }
            .foregroundStyle(.gray)
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } }
            if open {
                Text(text).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(white: 0.5))
                    .textSelection(.enabled).padding(.leading, 10)
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

// MARK: - where the transcript sits

/// Two facts about the transcript's own scroll, both straight from the OS.
///
/// `below`: is the newest line BELOW the fold? "Scroll to the bottom" is the
/// wrong move when it is already on screen - that case is the live block
/// shrinking, and pulling the chat there is the jump this design exists to
/// prevent. So the direction of the fix depends on this.
///
/// `touching`: is a finger on the transcript, or the momentum it left behind?
/// ONLY these may block following. A scroll this view makes itself arrives as
/// `.animating`, and treating that as the reader's was a bug that stopped
/// autoscroll completely: while text streams, an animation is retargeted over
/// and over, so `.animating` was nearly continuous and follow() never ran.
///
/// `settledByReader`: did a reader's gesture just come to rest? That is the only
/// moment the reader's place may be re-decided.
///
/// Both need iOS 18, and a lower deployment target cannot see the API at all
/// (a missing symbol is a compile error even inside `#available`). There the
/// caller falls back to comparing content height with the viewport -
/// direction-blind, but still enough to keep a transcript that fits the screen
/// from being nudged.
private struct TranscriptScroll: ViewModifier {
    /// Is the newest line below the fold? (called as the scroll moves)
    let onBottom: (Bool) -> Void
    /// (is a finger or its momentum moving it, did a READER's gesture just settle)
    let onPhase: (Bool, Bool) -> Void

    func body(content: Content) -> some View {
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { g in
                    // No room for a scroll means the newest line is on screen
                    // whatever the offset says - the state the app launches in.
                    // 1pt of slack: a scroll at rest reports its offset a
                    // fraction of a point short of the end.
                    !(g.contentSize.height <= g.containerSize.height
                      || g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 1)
                } action: { _, below in
                    onBottom(below)
                }
                .onScrollPhaseChange { old, new in
                    // The phases only a finger can produce. `.animating` is what a
                    // programmatic scroll looks like, and it is NOT the reader -
                    // which matters because this view's own scrolls are exactly
                    // that, and while text streams they are being retargeted
                    // constantly.
                    func byFinger(_ p: ScrollPhase) -> Bool {
                        p == .tracking || p == .interacting || p == .decelerating
                    }
                    onPhase(byFinger(new), new == .idle && byFinger(old))
                }
        } else {
            content
        }
        #else
        content
        #endif
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
