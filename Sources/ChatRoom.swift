//
//  ChatRoom.swift
//  The app's one navigation stack, the CHAT MENU (its root screen), and the live
//  stream.
//
//  This is the shape Alex asked for, in his words: "as I understand we want simple
//  navigation. Same way as settings window returns now to chat, chat should return
//  to menu and settings should return to menu too... simply do menu first window in
//  navigation stack and push chat on top". So the stack's ROOT is the menu,
//  Settings and the chat are both pushed onto it, and returning is the SYSTEM's
//  business: the bar's back button, the swipe from the left edge, and the pop
//  animation. Nothing here slides panels or fakes a drawer.
//
//  The menu is a screen of that stack and the chat is another, and that is what
//  makes the split below matter: a screen's @State dies when it is popped, so the
//  OPEN CHAT (ChatStore + EventFeed) and the STREAM cannot live in either of them.
//  They live here, the room, which is never popped - and so does the phone's
//  mirror of a turn running in the terminal, which is why the stream starts here
//  and not when a chat appears.
//

import SwiftUI

struct ChatRoom: View {
    @StateObject private var api = BishopAPI()
    @StateObject private var feed = EventFeed()
    @StateObject private var chat = ChatStore()

    /// The stack. Opening a chat or Settings appends; the back button and the edge
    /// swipe pop it, and the screen is gone when it leaves - which is why nothing
    /// that has to survive a pop is @State on a screen.
    @State private var path: [Screen] = []

    enum Screen: Hashable { case chat, settings }

    /// True once the app has opened on the chat. `.onAppear` fires AGAIN when the
    /// stack empties - the root is re-shown - so a launch that ran on every appear
    /// would re-push the chat the moment Back popped it, and the back button would
    /// look dead. (Watched on the simulator: tapping Back left the chat on screen,
    /// because the chat had just been pushed back on.)
    @State private var launched = false

    var body: some View {
        NavigationStack(path: $path) {
            MenuView(api: api, chat: chat, open: open)
                .navigationDestination(for: Screen.self) { s in
                    switch s {
                    case .chat: ChatView(api: api, events: feed, chat: chat)
                    case .settings: SettingsView(api: api)
                    }
                }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        // Alex: "2. ok to open chat first" - the app opens on the chat, and the
        // menu is one tap or one swipe away. Pushing in onAppear is what makes the
        // chat a PUSHED screen rather than a second root (see the note below).
        .onAppear {
            if !launched { launched = true; path = [.chat] }
            startStream()
        }
        // A NEW chat lands here, whichever pencil asked for it: a fresh transcript
        // has no room in the stack for a second screen, so the chat screen stays
        // where it is - except when the pencil was pressed from the MENU, which is
        // the room's own bar button, and then the chat has to be pushed.
        .onChange(of: api.session) { _, sess in
            if path.isEmpty, !chat.saved { path = [.chat] }
            // ...and the OPEN CHAT follows the server while it is still unsaved:
            // a chat the Mac has not written down can only be the one being
            // written, so its id is the server's. Once it IS saved, the id is
            // frozen - from then on "which chat is open" is the reader's choice,
            // made by the row they tapped, not the server's.
            if !chat.saved { chat.id = sess }
        }
        // The chat's NAME and whether the server has written it down are settled
        // here, on the poll both screens share, rather than read by the screens: the
        // menu may be off screen when a chat's title first arrives, and it is the
        // menu that lists that title - settled once, the list is never stale when it
        // comes back.
        .onChange(of: api.session) { _, _ in follow() }
        .onChange(of: api.sessions) { _, _ in follow() }
    }

    /// Refresh the open chat's identity from the server: what it is called, and
    /// whether it has been written down yet. ONE rule, and it cannot go stale: the
    /// title is what the server calls this chat, or "New chat" while it has not
    /// written it down yet, or "Bishop" for no chat at all.
    ///
    /// It does NOT touch `chat.id`: that is "which chat is open", decided by the
    /// tap that opened it, and a poll that reassigned it would follow a session the
    /// server happens to have switched to. `api.session` is only the SERVER's
    /// answer, and it is the menu, not this, that reads it to decide which row to
    /// tick.
    private func follow() {
        chat.saved = api.sessions.contains { $0.id == chat.id }
        chat.title = api.sessions.first { $0.id == chat.id }?.title
            ?? (chat.id.isEmpty ? "Bishop" : "New chat")
    }

    /// Open a chat from the menu: push the chat screen, then load it into the feed.
    ///
    /// The PUSH IS THE POINT, and it is why the chat may not be a second root
    /// screen: a root swap is not a navigation, so there would be no back button
    /// and no edge swipe. The push happens FIRST, so the screen arrives at once and
    /// the Mac answers behind it - five seconds of a menu that ignores a tap is
    /// worse than a screen that fills in.
    private func open(_ id: String) {
        // The chat already open is left in place: the screen is the same screen and
        // what is in it is current - re-loading it is a round trip that can only
        // redraw the same chat (and, mid-turn, cannot draw the streaming rows).
        if id == chat.id {
            if path.isEmpty { path = [.chat] }
            return
        }
        path = [.chat]
        chat.id = id
        chat.saved = false
        chat.title = id.isEmpty ? "New chat" : "Loading..."
        Task {
            if id.isEmpty {
                await api.newChat()
                // The server's session goes with the transcript: /api/chat reset
                // leaves `api.session` on the chat that just ended, and the room
                // reads the open chat off it - so without this the menu would tick
                // the old chat and `follow` would point this new one at it.
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

/// The chat menu: what the app opened with before this was a stack - the list of
/// chats, New chat and Settings - as the ROOT SCREEN of the navigation stack, which
/// is the one place it can be for the chat to push over it. The connected state is
/// pinned at the bottom: this is what a reader opens when the app seems dead, and
/// the state has to be readable without going anywhere.
struct MenuView: View {
    @ObservedObject var api: BishopAPI
    @ObservedObject var chat: ChatStore
    /// Open a chat by id ("" is a new one) - the room pushes it.
    let open: (String) -> Void

    var body: some View {
        // ONE list for both the current chat and the saved ones. Two Sections were
        // tried first and the "current chat" group was a phantom: the open chat is
        // the FIRST entry of the list below, marked with a tick, and grouping it
        // separately made the same chat appear twice the moment it was saved.
        List {
            Section("Chats") {
                // The UNSAVED chat is the first row when the open chat is not in
                // the server's list: a list that omitted the conversation the
                // reader is looking at would read as "my chat is gone". Once the
                // server has written it down it is in `api.sessions` like any
                // other, and the two do not double up.
                if !chat.saved {
                    chatRow(id: chat.id, title: chat.title)
                }
                ForEach(api.sessions) { s in
                    chatRow(id: s.id, title: s.title)
                }
                if api.sessions.isEmpty && chat.saved {
                    Text("Nothing saved yet").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Bishop")
        // The menu is the ROOT, so there is nothing to go back to and the bar
        // shows no back button - the chat's own bar is the one that pops.
        .navigationBarTitleDisplayMode(.inline)
        // New chat and Settings hang off the ROOT's bar rather than sitting in the
        // list: as list rows they were the first thing the chat list pushed down,
        // and neither of them is a chat.
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { open("") } label: { Image(systemName: "square.and.pencil") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: ChatRoom.Screen.settings) {
                    Image(systemName: "gearshape")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { status }
    }

    /// Which chat the server says is open. It is the MENU's rule, not the chat
    /// screen's: the room pushes a chat and calls `api.load`, and the load is what
    /// changes the session, so the menu would otherwise be ticking a chat the
    /// server is no longer on.
    private var current: String {
        api.session
    }

    /// One chat in the list. The current one is ticked, so the list says where the
    /// reader is - and because the menu survives a pop, it is up to date the moment
    /// they land back on it. Which chat is current is `api.session`, the server's
    /// own answer, rather than `chat.id`: a chat just started has no id until the
    /// next poll writes one, and its LIST ROW is what must not drift from that.
    private func chatRow(id: String, title: String) -> some View {
        Button { open(id) } label: {
            HStack {
                Text(title)
                Spacer()
                if id == current { Image(systemName: "checkmark").foregroundStyle(.secondary) }
            }
        }
        .foregroundStyle(.primary)
    }

    /// Which Mac this app is talking to, and whether it is answering. The address
    /// itself is on the Settings screen above; this is the one line that saves the
    /// trip when the app looks dead.
    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(api.connected ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(api.connected ? "Connected" : "Not connected").font(.footnote)
            Spacer()
            Text(api.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.black)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
    }
}