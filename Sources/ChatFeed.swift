//
//  ChatFeed.swift
//  The two things that must outlive a screen: the open chat (its id, title and
//  rendered rows) and the ONE live stream that fills them. Both were @State
//  inside ChatView until the chat became a PUSHED screen. A screen's state dies
//  with it, and popping back to the menu - the whole point of the navigation
//  stack - was taking the transcript with it, so returning to the chat showed an
//  empty one. The stream went with the screen too: a phone that goes to the menu
//  while Bishop is writing would stop receiving, and the turn would arrive
//  nowhere.
//
//  BishopAPI is unchanged and still the shared object it was (address, token,
//  sessions, counters, busy): it was @StateObject in ChatView, which is itself
//  @StateObject in BishopApp, so a room-level view holding it changes nothing.
//

import Foundation

/// The rendered rows of the open chat, in one observable object - and the rules
/// that turn streamed events into them. A reference type because every mutation
/// has to be seen by the SCREEN, and the screen is not the owner any more.
/// `rows` is one @Published array rather than a @Published on each row, so a batch
/// of streamed tokens is one objectWillChange and one redraw - exactly what the
/// @State array did.
final class EventFeed: ObservableObject {
    @Published var rows: [ChatEvent] = []

    /// One batch of streamed rows onto the transcript. A thought or an answer
    /// continues the last row of its kind if that is what it is; a tool call
    /// closes the open thought first, exactly like grow()/endThought() do in the
    /// browser.
    func merge(_ row: ChatEvent) {
        switch row.kind {
        case .answer where row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return                                   // invisible, as the page hides it
        case .thought, .answer:
            if let last = rows.last, last.kind == row.kind, last.open {
                rows[rows.count - 1].text += row.text
                return
            }
            closePhase()                             // a new thought folds the old one
            var fresh = row
            fresh.open = true
            rows.append(fresh)
        case .recall:
            insertRecall(row)
        case .tool:
            closePhase()
            // Arguments are re-sent as they stream, so a call already on screen
            // is UPDATED in place: the row stays one, and its name is what
            // identifies it when the stream carries no call id.
            if let i = toolRow(for: row) {
                rows[i].text = row.text
                if row.view != nil { rows[i].view = row.view }
                return
            }
            rows.append(row)
        case .result:
            closePhase()
            // A result joins the call above it (one row per call). With no call
            // to join it keeps its own row, folded as it always was.
            guard let i = toolRow(for: nil) else { rows.append(row); return }
            // The live output was the RUNNING command's; the result replaces it
            // (the row draws the result's own rows from here on), so the copy
            // goes rather than sitting under the finished output.
            rows[i].liveRows = []
            // The verdict was already read off this event while it was decoded,
            // when its call was in the same batch; a result that arrived alone
            // (the call long drawn) is judged here, by the same rule.
            let good = row.ok ?? Self.succeeded(row)
            rows[i].ok = good
            // A good edit said what happened in its chip; a failure says it here
            // and nowhere else, so it is kept whatever the view claims.
            rows[i].result = good && ToolView.speaksForItself(row.view) ? "" : row.text
            // The call's view DESCRIBES the row (an edit's chip and diff), the
            // result's only reports ("ok", true): never overwrite the former -
            // except for a read, whose content only exists in the result.
            rows[i].view = ToolView.describedBy(rows[i].view, row.view)
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
            rows[i].liveRows = row.liveRows
        default:
            closePhase()
            rows.append(row)
        }
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
        var at = rows.count
        while at > 0 && rows[at - 1].open { at -= 1 }
        rows.insert(row, at: at)
    }

    /// The row a tool event belongs to. A CALL continues the row just drawn if
    /// it is the same call - by the provider's id when both have one, otherwise
    /// by name, since the arguments are re-sent as they stream in. A RESULT
    /// belongs to the call above it, which is either the call this app just drew
    /// or, in a stored session replayed as a flat list, the one before it.
    private func toolRow(for row: ChatEvent?) -> Int? {
        guard let last = rows.indices.last, rows[last].kind == .tool else { return nil }
        guard let row else { return last }
        if !row.callId.isEmpty && !rows[last].callId.isEmpty {
            return row.callId == rows[last].callId ? last : nil
        }
        return rows[last].name == row.name ? last : nil
    }

    /// The turn really is running on the Mac now (the stream's `live` counters),
    /// so the thought it is writing may be timed from here. Everything before
    /// this arrived as a replay of words already written, which is why showing up
    /// in the middle of a thought leaves it unwatched - and, when it folds, with
    /// no duration rather than a fabricated "1s".
    func markWatched() {
        for i in rows.indices where rows[i].open && rows[i].kind == .thought && !rows[i].watched {
            rows[i].started = Date()
            rows[i].watched = true
        }
    }

    /// A phase boundary: a tool call, a result, or the end of the turn. The
    /// thought that was streaming folds into one dim line (with its duration, if
    /// this app was watching when it started), and on a finished turn nothing
    /// keeps taking text - so the next turn cannot append to a bubble from the
    /// previous one.
    func closePhase(everything: Bool = false) {
        for i in rows.indices where rows[i].open {
            if rows[i].kind == .thought {
                rows[i].open = false
                // A duration needs a clock that started while the thought was
                // still being written (markWatched) and at least two seconds of
                // it; anything else - a thought that arrived folded with a
                // reopened session, or one this app caught mid-flight - says
                // "thought" instead of inventing a number. Timing it from the
                // moment its rows were decoded is what made every line read
                // "thought for 1s".
                if rows[i].watched {
                    let secs = Int(Date().timeIntervalSince(rows[i].started))
                    if secs >= 2 { rows[i].secs = secs }
                }
            } else if everything {
                rows[i].open = false
            }
        }
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
}

/// Which conversation is open and what it is called. Held above the screen so the
/// menu can list chats, and open one, while no chat is on screen at all.
final class ChatStore: ObservableObject {
    /// The open chat's id, "" for the unsaved one.
    @Published var id = ""
    /// The name to put in the bar and in the menu's list. Kept here rather than
    /// looked up in the session list, because the open chat can be the UNSAVED one,
    /// which is in no list - and because the MENU is not on screen when the chat
    /// sets it.
    @Published var title = "Bishop"
    /// Has the server written this chat down? The APP cannot know - the Mac
    /// decides when a session starts existing. The server's own session list is
    /// the answer, and the ROOM reads it there and writes it here, so both the
    /// menu's list and this flag move on the same poll.
    @Published var saved = false
}