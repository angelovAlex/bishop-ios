//
//  ChatRoom.swift
//  The app's one navigation stack, the CHAT MENU (a screen pushed over the chat)
//  and the live stream.
//
//  The shape, which is Alex's, in his words: "we want simple navigation... simply
//  do menu first window in navigation stack and push chat on top" - and then, with
//  the Gemini app next to him: "in reference app it is possible to swipe back into
//  chat from menu". Those two together are what put the CHAT at the bottom of the
//  stack and the MENU above it: a swipe from the left edge POPS whatever screen is
//  on top, so for that gesture to end in the chat, the menu has to BE the screen on
//  top. Settings is pushed from the menu, and Back from either lands in the chat.
//  Nothing here draws a panel or fakes a drawer - every transition is a real push
//  or pop, which is what makes the system's own back button and edge swipe work.
//
//  A screen's @State dies when it is popped, so the OPEN CHAT (ChatStore) and the
//  live rows (EventFeed) and the STREAM cannot live in a screen. They live here,
//  the room, which is never popped - otherwise opening the menu would empty the
//  transcript and stop receiving a turn that is running on the Mac.
//

import SwiftUI

struct ChatRoom: View {
    @StateObject private var api = BishopAPI()
    @StateObject private var feed = EventFeed()
    @StateObject private var chat = ChatStore()

    /// The stack: empty is the chat, and the menu or Settings is pushed on top of
    /// it, so Back and the edge swipe always return to the chat.
    @State private var path: [Screen] = []

    enum Screen: Hashable { case menu, settings }

    var body: some View {
        NavigationStack(path: $path) {
            ChatView(api: api, events: feed, chat: chat, menu: { path.append(.menu) })
                .navigationDestination(for: Screen.self) { s in
                    switch s {
                    case .menu: MenuView(api: api, feed: feed, chat: chat, open: open)
                    case .settings: SettingsView(api: api)
                    }
                }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        // The stream starts with the ROOM, not with a screen: the Mac's turn is
        // mirrored here whether or not the chat is the screen in front.
        .onAppear { startStream() }
        .onChange(of: api.session) { _, sess in adopt(sess) }
        .onChange(of: api.sessions) { _, _ in follow() }
    }

    /// The Mac mints a session id for a chat the moment it has something to write
    /// down, and until this line the app kept calling that chat "" - so the menu
    /// listed it TWICE (the phantom "New chat" row plus the session it had just
    /// become), neither row ticked, and tapping the real one looked like a different
    /// chat and re-loaded it (Alex: "when same chat is opened it reloads it").
    /// Only an UNSAVED chat may take its id from the server: once a chat is open by
    /// name, which chat that is belongs to the reader's tap.
    private func adopt(_ sess: String) {
        if chat.id.isEmpty { chat.id = sess }
        follow()
    }

    /// Refresh the open chat's name and whether the server has written it down. ONE
    /// rule, and it cannot go stale: the server's name for this chat, or "New chat"
    /// while it has not written it down, or "Bishop" for no chat at all.
    private func follow() {
        chat.saved = api.sessions.contains { $0.id == chat.id }
        chat.title = api.sessions.first { $0.id == chat.id }?.title
            ?? (chat.id.isEmpty ? "Bishop" : "New chat")
    }

    /// Open a chat from the menu: load it and CLOSE the menu, because the chat is
    /// the screen underneath. The load happens behind that pop, so the reader is
    /// back in the chat at once and the transcript fills in.
    private func open(_ id: String) {
        // The chat already open is left exactly as it is - same screen, and what is
        // in it is current. Re-loading it is a round trip that can only redraw the
        // same chat (and, mid-turn, cannot draw the streaming rows at all).
        if id == chat.id {
            path = []
            return
        }
        path = []
        chat.id = id
        chat.saved = false
        chat.title = id.isEmpty ? "New chat" : "Loading..."
        chat.draft = ""                  // the draft belonged to the chat just left
        chat.attachments = []
        Task {
            if id.isEmpty {
                await api.newChat()
                // The server's session goes with the transcript: /api/chat reset
                // leaves `api.session` on the chat that just ended, and without
                // this the menu would tick the chat that just ended.
                api.session = ""
                feed.rows = [ChatEvent(kind: .info, text: "New conversation.")]
            } else {
                await api.load(session: id)
                if let (list, sess) = try? await api.events(session: nil) {
                    feed.rows = list
                    api.session = sess
                    await api.refresh()
                }
            }
            follow()
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
            for row in batch { feed.merge(row) }
        }, onLive: { feed.markWatched() }, onStart: {
            api.busy = true
            api.liveTokens = 0
        }, onEnd: {
            api.busy = false
            feed.closePhase(everything: true)   // a turn can end mid-thought, mid-answer
        })
    }
}

/// The chat menu, laid out like the reference (Gemini's): the title at the top, NEW
/// CHAT as the first row before any chat, then the chats, and SETTINGS down at the
/// bottom with the account/state line - Alex's four asks in order: "1. on reference
/// app settings at section in menu on bottom. 2. where you put settings button in
/// menu, there should be back button. ... 5. New chat should be item in menu window
/// before chats".
struct MenuView: View {
    @ObservedObject var api: BishopAPI
    @ObservedObject var feed: EventFeed
    @ObservedObject var chat: ChatStore
    /// Open a chat by id ("" is a new one) - the room loads it and pops this screen.
    let open: (String) -> Void

    /// The menu is the screen on TOP of the chat, so "close" is a pop - the same
    /// thing the edge swipe does. `dismiss` is that pop, and it is why the button in
    /// the bar needs no path of its own.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Button { open("") } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
            }
            Section("Chats") {
                // The OPEN chat is the first row when the server does not list it:
                // a fresh chat is a session the Mac has already made, but `recent()`
                // hides a session with no turn in it - so without this row the
                // reader's chat would be in no list at all, and the "New chat" row
                // above would READ as it. Tapping that is what started a SECOND chat,
                // which is what looked like "opening the same chat reloads it and
                // erases the input field" (Alex). Only once there is a transcript
                // worth going back to: an empty, untitled new chat IS "New chat".
                if !chat.saved && hasTurns {
                    chatRow(id: chat.id, title: chat.title)
                }
                ForEach(api.sessions) { s in
                    chatRow(id: s.id, title: s.title)
                }
                if api.sessions.isEmpty && !hasTurns {
                    Text("Nothing saved yet").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Bishop")
        // A LARGE title, like the reference's: it sits at the leading edge, which is
        // where the system's own back button has to be on a pushed screen. The back
        // chevron above it names the chat this menu was opened from - the same
        // journey as the X on the right and the swipe from the edge.
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Alex: "2. where you put settings button in menu, there should be back
            // button" - Settings moved to the bottom of the screen, and the X took
            // its place in the bar. It is the reference's own button, in the same
            // corner, doing the same thing: back to the chat.
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Back to the chat")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottom }
    }

    /// Settings, at the bottom of the menu and out of the chat list's way - the
    /// reference keeps its account and gear down here. The connected state rides
    /// with it: this is the screen a reader opens when the app seems dead, and both
    /// answers ("where is Settings", "is the Mac answering") are then in one place.
    private var bottom: some View {
        HStack(spacing: 12) {
            NavigationLink(value: ChatRoom.Screen.settings) {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            Spacer()
            Circle().fill(api.connected ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(api.connected ? "Connected" : "Not connected")
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.black)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
    }

    /// Has the open chat anything to go back to? A chat the server has not written
/// down may still have rows on screen (the reader's own message and a running
/// answer), and those are worth a row in the list; an empty new chat is not.
    private var hasTurns: Bool {
        feed.rows.contains { $0.kind == .user || $0.kind == .answer || $0.kind == .thought }
    }

    /// One chat in the list. The open one is ticked, so the list says where the
    /// reader is - and because the menu is re-shown rather than rebuilt, it is up to
    /// date the moment they land back on it.
    private func chatRow(id: String, title: String) -> some View {
        Button { open(id) } label: {
            HStack {
                Text(title)
                Spacer()
                if id == chat.id { Image(systemName: "checkmark").foregroundStyle(.secondary) }
            }
        }
        .foregroundStyle(.primary)
    }
}