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
    @State private var path: [ChatView.Screen] = []   // what the back menu pushed
    @State private var request: MenuRequest?  // what a menu row asked for; see carry(_:)
    @State private var mine: UUID?            // a just-sent message, to be put at the top
    @State private var content: CGFloat = 0   // how tall the transcript is
    @State private var viewport: CGFloat = 0  // ...and how much room it has
    @State private var following = true       // follow the newest text: the reader is at the bottom
    @State private var belowFold = false      // ...and the newest text is below the fold right now
    @State private var dragging = false       // a finger (or its momentum) is moving the transcript
    @State private var placing = false        // a just-sent message is on its way to the top
    @State private var geo = ScrollGeo()      // the scroll's raw numbers, for the debug strip
    @FocusState private var typing: Bool      // the composer's focus, so send() can drop the keyboard

    var body: some View {
        // The bars hang off the SCROLL VIEW itself, via safeAreaBar - see
        // BarsOverTranscript. Inside a VStack the transcript stopped at their
        // edge, so nothing ever scrolled under the glass and the glass itself was
        // impossible to see; only a direct child can be pinned like this and get
        // the scroll edge effect (the frosted band under a bar).
        // The stack wraps the WHOLE screen, bars included: Settings is pushed onto
        // THIS stack, and the header (which holds the menu that asks for it) hangs
        // off the scroll view through BarsOverTranscript - a stack around the
        // transcript alone would leave that header outside it.
        //
        // The push is driven by `path`, not by a NavigationLink in the menu. A
        // NavigationLink inside this Menu highlights its row, closes the menu and
        // pushes NOTHING (watched on the simulator, twice) - a menu row can only
        // report where to go, and the path is the state that actually goes there.
        NavigationStack(path: $path) {
            transcript
                .modifier(BarsOverTranscript(glass: glassBar, header: header, bottom: bottomBars))
                .navigationDestination(for: Screen.self) { s in
                    switch s {
                    case .settings: SettingsView(api: api)
                    }
                }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onChange(of: request) { _, r in
            guard let r else { return }
            request = nil                    // one tap, one request
            Task { await carry(r) }
        }
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
            // Back: a menu, not the session list. Alex, on the phone: "when
            // pressed back it should show a menu. in menu put setting button that
            // will navigate to settings window".
            //
            Menu { menuItems } label: {
                Image(systemName: "chevron.left").font(.system(size: 22, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Back, menu")

            // The title is plain, like the chevron: the menu it names is one tap
            // away on the left now, so the capsule became a caption with no job.
            Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 34)

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
            if showFollowDebug { followStrip }
            statsStrip
            composer
        }
    }

    /// OFF by default, and KEPT on purpose (Alex: "hide debug panel now, dont
    /// remove it completely"). It is the one place the follow logic can be read
    /// off the screen rather than reasoned about, and it already earned its keep:
    /// the autoscroll bug that survived several commits was found by subtracting
    /// the numbers it prints - cc43951 ct291 off43548 - which is a subtraction no
    /// amount of reading the code had produced. Flip this to true and rebuild when
    /// the transcript misbehaves again; it is a compile-time constant, so a
    /// release build carries none of it.
    private let showFollowDebug = false

    /// What the follow logic thinks, and the four numbers it is made of.
    ///
    /// Left: F `following` (the reader is at the newest text and autoscroll is
    /// armed), B `belowFold` (the newest line is under the bottom edge, so there is
    /// something to fix), D `dragging` (a finger or its momentum owns the scroll),
    /// P `placing` (a just-sent message is flying to the top). Green means armed.
    ///
    /// Right, in device points: cc content height, ct container height, off scroll
    /// offset, vis the bottom of the visible content, ins the bottom content inset
    /// the bars hold open. `below` is `vis < cc + ins` and nothing else, so a wrong
    /// one of these is visible here directly - which is the only reason the real
    /// bug was found.
    private var followStrip: some View {
        HStack(spacing: 6) {
            Text("follow\(following ? "1" : "0") below\(belowFold ? "1" : "0") drag\(dragging ? "1" : "0") place\(placing ? "1" : "0")")
                .font(.system(size: 10, design: .monospaced))
            Spacer()
            Text("cc\(Int(geo.content)) ct\(Int(geo.container)) off\(Int(geo.offset)) vis\(Int(geo.visibleMaxY)) ins\(Int(geo.bottomInset))")
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(following ? .green : .orange)
        .padding(.horizontal, 6).padding(.bottom, 2)
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

    // MARK: the back menu

    /// What a menu row asked for. A menu is dismissed the instant one of its
    /// buttons is chosen, so no row may start async work itself - it would be
    /// cancelled with the menu. Every button therefore only sets this value, and
    /// the one task below carries the request out. `nil` means nothing pending.
    struct MenuRequest: Equatable {
        var screen: Screen?               // push a screen (Settings)
        var newChat = false
        var session: String?
        var stop = false
        var speech = false
        var restart = false
    }

    /// A screen the chat can push. An enum rather than a bare Bool because the
    /// stack's path is the state that drives it: `NavigationLink` inside the
    /// chevron's Menu highlights the row and pushes NOTHING (verified on the
    /// simulator - the menu closes and the chat stays), so the menu reports the
    /// destination and the path does the pushing, which cannot silently fail.
    enum Screen: Hashable { case settings }

    /// The menu under the back chevron: the conversations, then Bishop's own
    /// switchboard. Alex: "when pressed back it should show a menu. in menu put
    /// setting button that will navigate to settings window".
    @ViewBuilder private var menuItems: some View {
        Button { request = MenuRequest(screen: .settings) } label: {
            Label("Settings", systemImage: "gearshape")
        }
        Divider()
        // The conversations sit in a submenu of their own: a dozen of them in the
        // same list as the app's controls is a wall the eye has to scan for
        // Settings, and they are what the menu is usually opened for.
        Menu {
            if api.sessions.isEmpty { Text("Nothing saved yet") }
            ForEach(api.sessions) { s in
                Button(s.title) { request = MenuRequest(session: s.id) }
            }
        } label: { Label("Conversations", systemImage: "bubble.left.and.bubble.right") }
        Button { request = MenuRequest(newChat: true) } label: {
            Label("New chat", systemImage: "square.and.pencil")
        }
        if api.busy {
            Button { request = MenuRequest(stop: true) } label: { Label("Stop the answer", systemImage: "stop.fill") }
        }
        Button { request = MenuRequest(speech: true) } label: {
            Label("Stop speaking", systemImage: "speaker.slash")
        }
        // No counters row here on purpose: the strip under the transcript is
        // already showing those two lines, and in the menu they wrapped onto
        // theirs and made the panel a wall. A menu repeats nothing it can point at.
        if api.connected {
            Divider()
            Button { request = MenuRequest(restart: true) } label: {
                Label("Restart the server", systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(events) { e in
                        EventRow(event: e, api: api, fullPicture: $fullPicture)
                            .id(e.id)
                    }
                    if !api.connected {
                        // The connect form is NOT here any more: a card in the
                        // transcript is in the path of the answer and, worse, it
                        // was the app's only way into the address - unreachable
                        // the moment a stale address stopped answering. It lives
                        // in Settings (menu > Settings) as of 2026-10-15; this is
                        // a signpost to it, and it draws NOTHING while the app is
                        // connected.
                        NotConnectedRow(api: api)
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
            .modifier(TranscriptScroll { g in
                // FOLLOWING is "the reader is at the newest text", and the
                // transcript being at its bottom IS that fact - so it is settled
                // here, on every geometry change, and not only when a gesture
                // ends. Nothing else ever turned it back on: Alex's report is
                // that autoscroll works until he touches the transcript once and
                // never returns after that. A finger on the glass is the one
                // exception - mid-drag the reader is still deciding - and a
                // scroll this view makes itself only ever brings the bottom UP,
                // to a place that was already on screen, so it cannot re-arm
                // anything by accident.
                geo = g                                  // the debug strip's numbers
                let below = g.below
                // TWO RULES, and between them they are the whole thing - Alex
                // named one each:
                //
                //   at the bottom            -> follow, always
                //   away from it under a hand -> do not
                //
                // "at the bottom" wins outright, so arriving there re-arms at once
                // even mid-flick ("it should reactivate green as soon as it reaches
                // bottom or more"), and a drag that starts at the bottom is not
                // thrown off by its own first frame. Being away from the bottom
                // only stops the follow while a finger OWNS the scroll - otherwise
                // a newline growing the composer, which pushes the bottom down for
                // the moment before the scroll catches up, would switch the follow
                // off by itself ("it is in green but once there is new line in
                // input field it goes orange again").
                //
                // This replaced `following = !below`, which turned the follow off
                // whenever the transcript was not at the exact bottom - so the
                // composer's growth and every ordinary frame of a drag could stop
                // it, and nothing but a send could start it again.
                if !below { following = true }
                else if dragging { following = false }
                belowFold = below
                // ...and having arrived at the bottom, WAKE the follow. Geometry
                // reports a new position from its own callback, where SwiftUI
                // writes no view state into the layout pass, so no onChange sees
                // the swing this change makes to `belowFold`: without this call a
                // reader who scrolls back down while text streams sits on hidden
                // text until the next token. Not mid-drag - that is the reader
                // still deciding - on arrival at the very bottom `dragging` has
                // already cleared whatever the gesture did.
                if !below, !dragging { follow(proxy) }
            } onPhase: { touching in
                // ONLY a finger, or the momentum it left behind, blocks following.
                // Not "not idle": this view's own scrolls report `.animating`, and
                // treating that as the reader meant that while text was arriving -
                // and the animation was being retargeted over and over - dragging
                // stayed true almost permanently and follow() returned early every
                // single time. That was "autoscroll does not work at all".
                dragging = touching
                // The hand is what stops the follow, and it stops it the moment the
                // drag is set rather than at the settle ("make it to disable follow
                // mode as soon as drag is set"). The geometry callback above applies
                // the other half - being AT the bottom re-arms, mid-gesture
                // included - so this only ever has to switch it off, and only while
                // the finger really owns the scroll.
                if touching { following = false }
                // ...and reaching the bottom brings it straight back, even if the
                // gesture is still in flight (a flick's momentum IS the reader
                // arriving). This is the other half of Alex's report: "it should
                // reactivate green as soon as it reaches bottom or more" - waiting
                // for the settle meant the strip only turned green once everything
                // had come to rest, and a gesture that ended a hair short of the
                // bottom left it orange for good. Arriving is a fact, so it is
                // decided by the fact, not by the gesture's end.
                if !belowFold { following = true }
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
    /// instead: the SESSION line is the brighter one - Alex asked for the swap
    /// ("Swap colors of current turn statistics line and current session
    /// statistics"), so the running total now carries full contrast and the last
    /// turn, read as a detail of it, sits dimmed below. `in` is the PROMPT at its
    /// true size (bill + c), which is also the context in play for the last turn;
    /// `bill` is the only part that costs money. Calls and the lifetime total
    /// live in the fold.
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
                                .foregroundStyle(.gray.opacity(0.55))
                            Text(counters(u.grossInput, u.cached, u.billedInput, u.output, u.sessionCost))
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
                    // No Spacer here: this row is inside a bar whose parent lets
                    // it grow, and a Spacer made it expand to fill the screen -
                    // "no call yet" floated in the middle of an empty chat. The
                    // chevron branch above wants a Spacer (it pushes the chevron
                    // right), this one has nothing to push.
                    Text("no call yet").bold()
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.gray)
            // A leading frame, because the bar's stack centres what it gets: the
            // figures read as a left-hand margin (Alex's layout), and without
            // this the two-line report floats to the middle of the screen.
            .frame(maxWidth: .infinity, alignment: .leading)
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
            // The reference bar is near-black (RGB 2,2,2) while the plain
            // material over this black page reads grey (18,18,18), so the
            // composer asks for a black tint - the one lever that darkens
            // liquid glass without painting over it.
            .glassBar(glassBar, radius: 26, fallback: Color(white: 0.11), tint: .black)
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
        dropKeyboard()          // the keyboard goes down and gives the answer the screen
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

    /// Take the keyboard down when a message goes out.
    ///
    /// NOT just `typing = false`, which is what this used to be: the composer
    /// hangs off the scroll view in a `safeAreaBar` (see BarsOverTranscript), and
    /// on iOS 26 a focused field inside a BAR does not honour a FocusState change
    /// - the keyboard simply stays up. Apple's forum has it as its own thread
    /// ("@FocusState Doesn't Work" in a toolbar, 797948): the same TextField moved
    /// out of the bar unfocuses normally, so the bug is the bar, not the binding.
    ///
    /// That is why this worked once and then stopped: nothing in `send()` changed,
    /// the composer's HOME did. On the iOS 18 SDK the app takes the legacy VStack
    /// branch (no safeAreaBar) and `typing = false` alone still dismisses - which
    /// is exactly why the local simulator build cannot reproduce Alex's report and
    /// the iOS 26 build can.
    ///
    /// resignFirstResponder goes through UIKit, below the focus engine, so it is
    /// not subject to the bar's bug. Both are called: FocusState still clears
    /// SwiftUI's own focus state to false, so the field is not left believing it
    /// is focused when it is not - it just cannot be the only lever.
    private func dropKeyboard() {
        typing = false
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        #endif
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

    /// Do ONE thing a menu row asked for. A menu is already gone by the time this
    /// runs, so nothing here can be cancelled by the dismissal - and the request is
    /// cleared before the work starts (in the body's onChange), so a second tap is
    /// a second run rather than a repeat of the first.
    private func carry(_ r: MenuRequest) async {
        if let s = r.screen { path.append(s) }
        if r.newChat { await newChat() }
        if let id = r.session { await open(id) }
        if r.stop { stop() }
        if r.speech { await api.stopSpeech() }
        if r.restart { await api.restartServer() }
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
            // The live output was the RUNNING command's; the result replaces it
            // (the row draws the result's own rows from here on), so the copy
            // goes rather than sitting under the finished output.
            events[i].liveRows = []
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
        case .output:
            // A command printing WHILE it runs. It lands on the row its call
            // opened and nowhere else: the whole output so far REPLACES the copy
            // there, because the Mac re-sends all of it every time - so a report
            // this app missed is corrected by the next one, and there is no
            // accumulation to keep in step. No call on screen (a list starting
            // with an output event) means nothing to draw on.
            //
            // The lookup passes the ROW, so the provider's call id decides: two
            // commands in one turn are two rows, and a report must not fill the
            // wrong one - the same id rule that pairs a result with its call.
            guard let i = toolRow(for: row) else { return }
            events[i].liveRows = row.liveRows
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
                         ok: event.ok, live: event.liveRows)
            } else {
                ToolRow(event: event)
            }
        case .result:
            // A tool result with no call above it to join. Folded, as before.
            if let v = event.view, v.kind == "ok", v.ok { EmptyView() }
            else if let v = event.view, ToolView.describes(v) {
                EditChip(view: v, raw: "", result: event.ok == false ? event.text : "")
            } else { Collapsible(summary: event.name, text: event.text, mono: true, tint: .gray) }
        case .output:
            // A command's output while it runs belongs to the row its call opened
            // (`merge` puts it there). With no such row on screen - a transcript
            // that began mid-run - there is nowhere to draw it, and the result
            // will carry the whole output anyway.
            EmptyView()
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
    /// A running command's output so far, straight off its row (`ChatEvent
    /// .liveRows`) - beside `view` rather than inside it because it is the ROW's
    /// state, like `result` and `ok`: it arrives after the call's view was built,
    /// and the view it belongs to is the same view the whole time.
    var live: [ToolView.Row] = []
    /// nil until the user taps: a READ and a SEARCH are born folded, an EDIT (a
    /// diff, and the only place those lines are written down) is born open. Alex
    /// asked for the read to stop dumping a whole file into the transcript on
    /// arrival - and a search is the same case, at 300 hits.
    ///
    /// A COMMAND that a front end is drawing as it runs (`stream`) is born open
    /// too and STAYS open: the output arriving is the whole point of the row, and
    /// folding it would hide the very thing being watched. That is not a rule of
    /// its own here - `open` is what it always was, and `stream` is carried on the
    /// row from the moment its call arrived, through the result, so nothing flips
    /// it shut when the command finishes.
    @State private var tapped: Bool? = nil
    @State private var showCall = false

    private var read: Bool { view.kind == "read" }
    private var search: Bool { view.kind == "search" }
    /// A COMMAND: the box holds the command, the verdict is its exit code and the
    /// duration rides inside the box (it is the figure for the command it timed).
    /// It is the only chip drawn while it is STILL HAPPENING - the call arrives
    /// before the tool has answered, and that is what the wheel is for.
    private var shell: Bool { view.kind == "shell" }
    /// Is this command being drawn WHILE it runs? Then its row is born open, and
    /// what it draws is the output so far (`liveRows`) until the result lands.
    private var streaming: Bool { shell && view.stream }
    private var open: Bool { tapped ?? (streaming || !(read || search || shell)) }
    /// A command's lines: the LIVE output while it runs, the result's own once it
    /// has answered. `liveRows` is empty in every case but a running command, so
    /// this is the result's rows in practice - and the two can never be shown at
    /// once, because `merge` clears the live copy when the result lands.
    ///
    /// A running command with NOTHING to show draws nothing at all. Alex asked for
    /// the "waiting for output" placeholder to go (2026-10-15): the wheel beside
    /// "Running" already says the command is going, so a card saying it in words
    /// was one thing too many - and with the command on a terminal (tools.py) the
    /// first line now arrives promptly, so the empty moment is brief in any case.
    private var bodyRows: [ToolView.Row] { live.isEmpty ? view.rows : live }
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
            if open, !bodyRows.isEmpty || !shownResult.isEmpty {
                if !bodyRows.isEmpty {
                    // Scrolls sideways rather than wrapping: a wrapped line pushes
                    // its continuation under the +/- marker, and the marker is what
                    // the eye follows down the block.
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(bodyRows) { r in
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

/// The one row the transcript still owns in the connect story: a signpost, drawn
/// ONLY while the Mac is not answering.
///
/// The form it replaces (ConnectBanner: address field, token field, Connect) was
/// wrong twice over. It sat INSIDE the transcript, where it pushed the answer down
/// and had to be scrolled past, and it was the app's ONLY way to reach the address
/// - so once a stale address stopped answering, the one screen that could have
/// fixed it was the one screen the app could not reach, and the card's own
/// "Connect" button only ever retried the same stale address. Settings (menu >
/// Settings) now owns all of it; this row says so, and names the address being
/// tried, because "not connected" without an address says nothing about which Mac
/// or which lease is at fault.
struct NotConnectedRow: View {
    @ObservedObject var api: BishopAPI

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "wifi.exclamationmark")
                Text("Not connected").fontWeight(.semibold)
                Spacer()
            }
            Text("Trying \(api.host.isEmpty ? BishopAPI.DEFAULT_HOST : api.host)")
            Text("Open the menu (top left) and then Settings to set the Mac's address and the token.")
        }
        .font(.system(size: 12))
        .foregroundStyle(.gray)
        .padding(.horizontal, 14)
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
/// The division of labour, and it is what Alex's last two reports pinned down:
/// a TOUCH is the only thing that may stop following, and it stops it the instant
/// the finger lands; reaching the BOTTOM is the only thing that may start it, and
/// it starts it the instant the bottom arrives - mid-gesture, mid-momentum, even
/// while the composer is growing under a newline. Deciding either one anywhere
/// else is how the strip went orange while he was only typing.
///
/// Both need iOS 18, and a lower deployment target cannot see the API at all
/// (a missing symbol is a compile error even inside `#available`). There the
/// caller falls back to comparing content height with the viewport -
/// direction-blind, but still enough to keep a transcript that fits the screen
/// from being nudged.
/// `onScrollGeometryChange` hands these three numbers over as one value; the
/// "is the newest line below the fold?" test is made of them, and the debug strip
/// prints them raw. Boiling them down to one Bool first is exactly what hides a
/// degenerate measurement - a container of 0 reads as "below the fold" forever,
/// and then nothing can ever re-arm the follow.
struct ScrollGeo: Equatable {
    var content: CGFloat = 0
    var container: CGFloat = 0
    var offset: CGFloat = 0
    var visibleMaxY: CGFloat = 0
    /// How far the transcript is allowed to scroll on UNDER the bottom bars.
    var bottomInset: CGFloat = 0
    /// The content height the scroll actually has to travel: the transcript plus
    /// the room the bars claim below it. At the very bottom `visibleMaxY` equals
    /// this, which is what makes "am I there?" an equality and not a guess.
    var reach: CGFloat { content + bottomInset }

    /// Is any of the newest line still hidden under the bottom edge?
    ///
    /// Measured against the VISIBLE RECT, not `offset + container`. That sum was
    /// the bug on Alex's phone: under a `safeAreaBar` the bar's height is not in
    /// `containerSize`, so the sum stops 112pt short of `contentSize` - exactly
    /// the bottom bars - and the test can never see the bottom. Read off his
    /// phone at the very bottom of a 43951pt transcript: cc43951 ct291 off43548,
    /// i.e. offset + container = 43839, 112 short of the end. `below` was stuck
    /// true, `following` was therefore stuck false, and the ONLY thing left that
    /// could set it was send() - which is precisely his symptom ("follow only
    /// sets when a new message is sent... I cant reactivate it by scrolling").
    ///
    /// `visibleRect` is the part of the content actually on screen, so it carries
    /// whatever insets the bars added and cannot disagree with the view the
    /// reader is looking at.
    ///
    /// The `bottomInset` term is the second half of the same story, and Alex found
    /// it by eye: "there is now a big zone where it stays green". Comparing
    /// `visibleMaxY` with `contentSize` alone went green as soon as the END OF THE
    /// CONTENT came into view - but the transcript can still scroll 556pt further,
    /// because the bottom bars hold that much room open below it. So green arrived
    /// more than half a screen early. The bottom is `content + bottomInset`, the
    /// point where the scroll actually stops, and at the very bottom his phone
    /// reads vis48246 cc47690 - 556 apart, which is the inset, exactly.
    ///
    /// The `content <= container` half stays: a transcript that fits the screen
    /// has no bottom to reach, and `reach` would otherwise be positive for a chat
    /// that cannot scroll at all.
    var below: Bool { !(content <= container || visibleMaxY >= reach - 1) }
}

private struct TranscriptScroll: ViewModifier {
    /// The scroll's geometry, as it moves. Handed over whole rather than
    /// pre-reduced to the `below` test, so the caller can show the three numbers
    /// the test is made of - a wrong container or content height is invisible
    /// once it has been boiled down to one Bool.
    let onGeo: (ScrollGeo) -> Void
    /// Is a finger, or the momentum it left behind, moving the transcript?
    let onPhase: (Bool) -> Void

    func body(content: Content) -> some View {
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: ScrollGeo.self) { g in
                    ScrollGeo(content: g.contentSize.height,
                              container: g.containerSize.height,
                              offset: g.contentOffset.y,
                              visibleMaxY: g.visibleRect.maxY,
                              bottomInset: g.contentInsets.bottom)
                } action: { _, g in
                    onGeo(g)
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
                    onPhase(byFinger(new))
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
    func glassBar(_ glass: Bool, radius: CGFloat, fallback: Color, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            // Under glass the fill has to go: the material is translucent, so a
            // dark slab behind it just greys it out.
            .background(glass ? Color.clear : fallback)
            .clipShape(shape)
            .modifier(GlassOn(glass: glass, shape: shape, tint: tint))
    }
}

private struct GlassOn: ViewModifier {
    let glass: Bool
    let shape: RoundedRectangle
    /// A colour blended INTO the material, not painted over it: `Glass.tint` is
    /// the one lever that darkens liquid glass, and nil is the plain material.
    /// Alex on the composer: "input field is greyish color, while on reference
    /// picture it is more dark" - the reference bar measures RGB 2,2,2 while the
    /// untinted material over this black page measured 18,18,18, so the glass
    /// itself is the pale veil. The composer therefore asks for a black tint; the
    /// header bars, signed off as they are, keep the plain material.
    var tint: Color?

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if glass, #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint), in: shape)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
