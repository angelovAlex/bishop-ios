//
//  JobsView.swift
//  What the Mac is doing on its own: the background jobs, and the log of what they
//  did. The phone's copy of the web page's Jobs/Activity sheet (webui.html), which
//  is the design Alex asked for and the one he has already used.
//
//  One screen with two halves, not two pushed screens: a job and its runs are two
//  views of the same thing, and splitting them would hide half the answer behind a
//  Back tap. A job row taps through to JobDetailView, which is where a job is read
//  and edited; a run row taps through to the CHAT that run happened in - a run IS an
//  ordinary conversation on disk, so its transcript needs no viewer of its own, only
//  the chat that already knows how to draw one.
//
//  Nothing here is fetched from a second endpoint: GET /api/jobs answers with the
//  records AND the activity log in one reply, exactly as the page expects it, so the
//  screen can never be half-drawn from two replies that disagree.
//

import SwiftUI

struct JobsView: View {
    @ObservedObject var api: BishopAPI
    /// Open a chat by id - a run's transcript. The CLOSURE, not a push: the chat is
    /// the root of this stack, so opening one means coming back to it (ChatView
    /// hands this down and does the popping).
    var open: (String) -> Void
    /// Push one job's detail screen, by id. Also a CLOSURE, not a NavigationLink:
    /// this app has already measured (twice, on the simulator) that a
    /// `NavigationLink` inside a hand-built list of rows highlights its row and
    /// pushes NOTHING, so a navigation-list row here would be a row that silently
    /// does not work. The stack's own path is the state that actually pushes.
    var openJob: (String) -> Void

    @State private var state: JobsState?
    @State private var error = ""

    var body: some View {
        List {
            if !error.isEmpty {
                Section { Text(error).foregroundStyle(.orange).font(.footnote) }
            }
            tickSection
            jobsSection
            activitySection
        }
        .navigationTitle("Jobs")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .refreshable { await load() }
        // The countdown has to be a countdown, and there is only one clock that knows
        // when the next run is due for real: the Mac's. So the screen re-reads rather
        // than doing its own arithmetic - the same choice the page makes with its
        // poll, and the reason a job that finishes stops saying "running now" without
        // anyone touching the phone. The loop also restarts on the way back from a
        // job's detail screen (SwiftUI cancels a `.task` when the view goes away), so
        // an edit made there is visible the moment it is popped.
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                await load()
            }
        }
    }

    // MARK: the three sections

    /// Who owns the schedule. Worth saying out loud: two Bishop servers can run at
    /// once on this Mac and share one jobs.json, and only the one holding the lock
    /// starts runs by itself - a phone showing a countdown on a server that is not
    /// ticking would be lying about the most important thing on the screen.
    @ViewBuilder private var tickSection: some View {
        Section {
            HStack(spacing: 8) {
                Circle().fill(state?.ticking == true ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(state?.ticking == true ? "This Mac runs the schedule"
                                            : "Another server owns the schedule")
                    .font(.footnote)
                Spacer()
                if let t = state?.tick, t > 0 {
                    Text("checks every \(jobSpan(t))").font(.caption2).foregroundStyle(.secondary)
                }
            }
        } footer: {
            if state?.ticking == false {
                Text("\"Run now\" still works here; runs will not start on their own from this server.")
            }
        }
    }

    @ViewBuilder private var jobsSection: some View {
        Section("Jobs") {
            if let jobs = state?.jobs, jobs.isEmpty {
                Text("No jobs yet. Ask Bishop in the chat to create one - \"every "
                     + "morning at 7, check the weather and write it down\".")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(state?.jobs ?? []) { job in
                Button { openJob(job.id) } label: { jobRow(job) }
                    .buttonStyle(.plain).foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder private var activitySection: some View {
        Section("Activity") {
            if state?.activity.isEmpty != false {
                Text("No runs recorded yet.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(state?.activity ?? []) { row in
                activityRow(row)
            }
        }
    }

    // MARK: rows

    /// One job: what it is, whether it is enabled, and when it runs next. The whole
    /// row is the tap target into its detail screen, so it carries no buttons of its
    /// own - Run now and On/Off belong where the job's text is, not on a line in a
    /// list where a mis-tap is invisible.
    private func jobRow(_ j: Job) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(jobLevelTag(j.level)).font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(jobLevelColor(j.level))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                Text(j.name).font(.system(size: 15, weight: .semibold))
                if j.running { ProgressView().controlSize(.mini) }
                Spacer()
                Text(j.running ? "running now" : (j.enabled ? "next in " + jobCountdown(j.due_in)
                                                             : "paused"))
                    .font(.caption).foregroundStyle(j.enabled ? Color.secondary : Color.orange)
            }
            Text("every \(jobSpan(j.interval_seconds)) \u{00B7} "
                 + jobLevelWords(j.level, mode: j.mode)
                 + (j.last_run.map { " \u{00B7} last ran \(jobCountdown(Int(state?.now ?? 0) - Int($0))) ago" } ?? "")
                 + (j.owner.isEmpty ? "" : " \u{00B7} \(j.owner)"))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// One line of the log. A row that names a SESSION is a way into that run's
    /// transcript; a row with none (a "missed" run, which never happened) is not a
    /// button, because there is nothing behind it - the web page's rows are all
    /// buttons and a missed one opens an empty chat.
    @ViewBuilder private func activityRow(_ r: ActivityRow) -> some View {
        if r.session.isEmpty {
            activityLabel(r)
        } else {
            Button { open(r.session) } label: { activityLabel(r) }
                .buttonStyle(.plain).foregroundStyle(.primary)
        }
    }

    private func activityLabel(_ r: ActivityRow) -> some View {
        HStack(spacing: 8) {
            Text(jobClock(r.ts)).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(jobLevelTag(r.level)).font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(jobLevelColor(r.level))
                    Text(r.name).font(.system(size: 13))
                }
                if !r.detail.isEmpty {
                    Text(r.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(r.state).font(.caption2.weight(.medium)).foregroundStyle(stateColor(r.state))
            if let s = r.seconds { Text(jobSecs(s)).font(.caption2).foregroundStyle(.secondary) }
            if !r.session.isEmpty {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func stateColor(_ s: String) -> Color {
        switch s {
        case "done": return .green
        case "error": return .red
        case "missed": return .orange
        default: return .secondary
        }
    }

    private func load() async {
        do {
            state = try await api.jobs()
            error = ""
        } catch let e {
            error = e.localizedDescription
        }
    }
}

// MARK: - one job, editable

/// A single job, and everything a phone can do to it: read its system prompt (Alex
/// asked to be able to SEE it, and the phone is where it is read most), edit it and
/// the input, pick the interval, switch it on or off, run it now, delete it.
///
/// What a write does is the page's behaviour, kept deliberately: a text or interval
/// change is one explicit Save (three fields, one request), while On/Off and Run now
/// act at once - a toggle that needed a second tap to mean anything would be a lie
/// about what it does.
struct JobDetailView: View {
    @ObservedObject var api: BishopAPI
    let id: String
    /// Told after a write succeeds. Optional, because the list behind this screen
    /// already re-reads on its five-second loop and again when this screen is
    /// popped (its `.task` restarts) - so a caller with nothing to add can leave
    /// this out, and one that wants an immediate redraw can pass it.
    var changed: () -> Void = {}

    @State private var job: Job?
    @State private var prompt = ""
    @State private var input = ""
    @State private var interval = 0
    @State private var note = ""
    @State private var bad = false
    @State private var busy = false
    @State private var confirming = false
    @State private var gone = false          // deleted: this screen has nothing left to show

    /// The intervals a phone is likely to want. A free-text field (which the page
    /// has, so "every 30 minutes" can be typed) is the wrong instrument on a phone
    /// keyboard: the reader would have to remember the parser's grammar.
    private static let INTERVALS: [(String, Int)] = [
        ("every minute", 60), ("every 5 minutes", 300), ("every 15 minutes", 900),
        ("every 30 minutes", 1800), ("every hour", 3600), ("every 6 hours", 21600),
        ("every day", 86400),
    ]

    var body: some View {
        Form {
            statusSection
            Section {
                TextEditor(text: $prompt)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 150)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("System prompt")
            } footer: {
                Text("How its runs behave. This is what the job's every run is told beyond "
                     + "the input below.")
            }
            Section {
                TextEditor(text: $input)
                    .font(.system(size: 14))
                    .frame(minHeight: 90)
            } header: {
                Text("Input")
            } footer: {
                Text("What every run is asked to do.")
            }
            Section {
                Picker("Interval", selection: $interval) {
                    ForEach(Self.INTERVALS, id: \.1) { Text($0.0).tag($0.1) }
                    if !Self.INTERVALS.contains(where: { $0.1 == interval }) {
                        Text("every \(jobSpan(interval))").tag(interval)
                    }
                }
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Text("Save prompt, input and interval")
                        if busy { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(busy || job == nil)
            } footer: {
                if !note.isEmpty {
                    Text(note).foregroundStyle(bad ? .orange : .green)
                }
            }
            Section {
                Toggle("Enabled", isOn: Binding(
                    get: { job?.enabled ?? false },
                    set: { v in Task { await setEnabled(v) } }))
                    .disabled(busy || job == nil)
                Button("Run now") { Task { await runNow() } }
                    .disabled(busy || job == nil)
                Button("Delete this job", role: .destructive) { confirming = true }
                    .disabled(busy || job == nil)
            } footer: {
                Text("Deleting the job keeps the transcripts of the runs it already "
                     + "made - they stay in logs/, and in Activity on the previous screen.")
            }
        }
        .navigationTitle(job?.name ?? "Job")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task { await load() }
        .confirmationDialog("Delete this job?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its runs' transcripts stay in logs/.")
        }
        // A job that was deleted here must not be saved by a stray field change while
        // the screen is still on its way out.
        .disabled(gone)
    }

    @ViewBuilder private var statusSection: some View {
        Section {
            HStack(spacing: 8) {
                Circle().fill((job?.enabled ?? false) ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(job?.running == true ? "Running now"
                     : ((job?.enabled ?? false) ? "On - next in \(jobCountdown(job?.due_in ?? 0))"
                                                : "Paused"))
                Spacer()
                Text(jobLevelWords(job?.level ?? "task", mode: job?.mode ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let j = job {
                Text(j.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        do {
            let s = try await api.jobs()
            guard let j = s.jobs.first(where: { $0.id == id }) else {
                note = "This job is no longer on the Mac."; bad = true; return
            }
            job = j
            prompt = j.system_prompt                 // only re-seeded on load, never
            input = j.input                          // while the reader is typing
            interval = j.interval_seconds   // an interval the picker does not list
                                            // gets its own row (see the Picker)
        } catch let e {
            note = e.localizedDescription; bad = true
        }
    }

    private func save() async {
        busy = true
        do {
            _ = try await api.jobSave(id, ["system_prompt": prompt, "input": input,
                                           "interval_seconds": interval])
            note = "Saved."; bad = false
            changed()
        } catch let e {
            note = e.localizedDescription; bad = true
        }
        busy = false
        await load()          // the schedule may have been re-armed by the save
    }

    private func setEnabled(_ v: Bool) async {
        busy = true
        do {
            _ = try await api.jobSave(id, ["enabled": v])
            note = v ? "Enabled - the tick will run it again." : "Paused - the tick will leave it alone."
            bad = false
            changed()
        } catch let e {
            // A refusal here is the common one: the schedule cannot be changed under a
            // run that is in flight (409). The reader is told rather than left with a
            // toggle that flipped back for no stated reason.
            note = e.localizedDescription; bad = true
        }
        busy = false
        await load()
    }

    private func runNow() async {
        busy = true
        do {
            let session = try await api.jobRun(id)
            note = session.isEmpty ? "Started." : "Started in session \(session)."
            bad = false
            changed()
        } catch let e {
            note = e.localizedDescription; bad = true
        }
        busy = false
        await load()
    }

    private func remove() async {
        busy = true
        do {
            try await api.jobDelete(id)
            gone = true
            changed()
            await load()      // reports "no longer on the Mac", which is now true
        } catch let e {
            note = e.localizedDescription; bad = true
        }
        busy = false
    }
}

// MARK: - the figures, spelled the way the page spells them

/// A level as the page names it: "L0", "L1", "L2". Short on purpose - it sits in a
/// row beside a name, and the interesting part is the difference, not the word.
func jobLevelTag(_ level: String) -> String {
    switch level {
    case "tool": return "L0"
    case "think": return "L2"
    default: return "L1"
    }
}

/// What a run of that level IS, in the page's words: a sense with no model, an
/// ordinary task in its mode, or the mind thinking. Used where there is room for a
/// phrase rather than a tag.
func jobLevelWords(_ level: String, mode: String) -> String {
    switch level {
    case "tool": return "level 0 - no model"
    case "think": return "level 2 - thinking"
    default: return "level 1 - \(mode) mode"
    }
}

/// A level's colour: a sense is deliberately dim (it is the quiet half of the house),
/// the mind takes the accent, and a task - the ordinary case - stays plain.
func jobLevelColor(_ level: String) -> Color {
    switch level {
    case "tool": return .secondary
    case "think": return .accentColor
    default: return .primary
    }
}

/// An interval as a length of time: "5m", "2h", "1d". Seconds when nothing divides
/// it, which is what an odd interval gets instead of being rounded into a lie.
func jobSpan(_ s: Int) -> String {
    for (n, unit) in [(86400, "d"), (3600, "h"), (60, "m")] where s >= n && s % n == 0 {
        return "\(s / n)\(unit)"
    }
    return "\(s)s"
}

/// A countdown to the next run: the largest useful two units, never "0m".
func jobCountdown(_ s: Int) -> String {
    if s <= 0 { return "now" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m \(s % 60)s" }
    return "\(s)s"
}

/// A unix timestamp as wall-clock time. The server's clock is the Mac's, and this
/// app runs on the phone - the two agree because the log was written by the Mac,
/// which is the only clock that stamped it.
func jobClock(_ ts: Double) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(Date(timeIntervalSince1970: ts)) ? "HH:mm" : "d MMM HH:mm"
    return f.string(from: Date(timeIntervalSince1970: ts))
}

/// How long a run took: seconds under a minute, then minutes and seconds.
func jobSecs(_ s: Double) -> String {
    let n = Int(s.rounded())
    if n < 60 { return "\(n)s" }
    if n < 3600 { return "\(n / 60)m\(n % 60)s" }
    return "\(n / 3600)h\((n % 3600) / 60)m"
}