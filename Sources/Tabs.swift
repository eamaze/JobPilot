import SwiftUI

struct TabPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(28)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Search

struct SearchTab: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @EnvironmentObject var engine: SearchEngine

    var body: some View {
        TabPage {
            PageHeader(title: "Search", subtitle: engine.status) {
                HStack(spacing: 10) {
                    if engine.working { ProgressView().controlSize(.small) }
                    Text(engine.enabled ? "On" : "Off").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(engine.enabled ? Color.crimson : Color.secondary)
                    Toggle("", isOn: Binding(get: { engine.enabled }, set: { v in withAnimation(.smooth) { engine.setEnabled(v) } }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.large)
                }
            }

            HStack(spacing: 12) {
                stat("\(engine.checked)", "Reviewed this session")
                stat("\(engine.matched)", "Matches this session")
                Button { withAnimation(.smooth) { app.tab = .results } } label: {
                    stat("\(store.data.results.count)", "Waiting in Results")
                }.buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label2("What you're looking for")
                TextEditor(text: $store.data.preferences)
                    .font(.system(size: 13)).scrollContentBackground(.hidden)
                    .frame(minHeight: 84, maxHeight: 140)
                    .padding(6)
                    .background(Color.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Location").font(.system(size: 12, weight: .medium))
                        TextField("Taken from the description if empty", text: $store.data.search.location).input()
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Minimum fit score").font(.system(size: 12, weight: .medium))
                        Seg(options: [("60", 60), ("70", 70), ("80", 80), ("90", 90)], selection: $store.data.search.minScore)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Search every").font(.system(size: 12, weight: .medium))
                        Seg(options: [("15 min", 15), ("30 min", 30), ("1 h", 60), ("3 h", 180)], selection: $store.data.search.intervalMinutes)
                    }
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 4) {
                Label2("Sources").padding(.bottom, 6)
                ForEach(JobSource.all) { s in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).font(.system(size: 13, weight: .medium))
                            Text(s.note).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let url = s.signInURL {
                            Button("Sign in") {
                                withAnimation(.smooth) { app.browser = BrowserSession(title: s.title, url: url) }
                            }.buttonStyle(SoftButton())
                        }
                        Toggle("", isOn: Binding(get: { store.data.search.sources[s.id] ?? false },
                                                 set: { store.data.search.sources[s.id] = $0 }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                    .padding(.vertical, 6)
                    if s.id != JobSource.all.last?.id { Divider() }
                }
                if store.data.search.sources["custom"] ?? false {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.data.search.customURLs.indices, id: \.self) { i in
                            HStack {
                                TextField("https://company.com/careers", text: Binding(
                                    get: { i < store.data.search.customURLs.count ? store.data.search.customURLs[i] : "" },
                                    set: { if i < store.data.search.customURLs.count { store.data.search.customURLs[i] = $0 } })).input()
                                IconButton(symbol: "minus.circle", help: "Remove") {
                                    if i < store.data.search.customURLs.count { store.data.search.customURLs.remove(at: i) }
                                }
                            }
                        }
                        Button { store.data.search.customURLs.append("") } label: { Label("Add page", systemImage: "plus") }
                            .buttonStyle(SoftButton())
                    }
                    .padding(.top, 6)
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 8) {
                Label2("Activity")
                if engine.log.isEmpty {
                    Text("Turn search on to start. JobPilot looks for new listings, skips anything you have already applied to or dismissed, and sends good fits to Results.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(engine.log.prefix(80)) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(color(line.kind)).frame(width: 6, height: 6).offset(y: -1)
                            Text(line.text).font(.system(size: 12.5)).foregroundStyle(line.kind == .skip ? .secondary : .primary)
                                .lineLimit(2)
                            Spacer()
                            Text(line.time.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .card()
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 22, weight: .bold).monospacedDigit()).contentTransition(.numericText())
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .card(14)
    }

    private func color(_ k: LogLine.Kind) -> Color {
        switch k {
        case .match: return .crimson
        case .error: return .orange
        case .skip: return .secondary.opacity(0.4)
        case .info: return .secondary
        }
    }
}

// MARK: - Results

struct ResultsTab: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store

    var body: some View {
        TabPage {
            PageHeader(title: "Results", subtitle: "Listings the AI judged a good fit. Apply, open, or dismiss.") {
                if !store.data.results.isEmpty { Pill(text: "\(store.data.results.count) waiting", color: .crimson, solid: true) }
            }
            if store.data.results.isEmpty {
                EmptyState(symbol: "sparkles.rectangle.stack", title: "No matches yet",
                           message: "Good fits appear here while search is on.")
            } else {
                ForEach(store.data.results) { job in
                    JobCard(job: job).transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
    }
}

struct JobCard: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    let job: Job
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title).font(.system(size: 15.5, weight: .semibold))
                    Text([job.company, job.location, job.source].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Pill(text: "\(job.score)% fit", color: .crimson, solid: true)
            }
            if !job.reason.isEmpty {
                Text(job.reason).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            if expanded {
                Text(job.description.isEmpty ? "No description was available for this listing." : job.description)
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                Button { app.apply(to: job) } label: { Label("Autofill & apply", systemImage: "wand.and.stars") }
                    .buttonStyle(PrimaryButton())
                Button { if let u = URL(string: job.url) { NSWorkspace.shared.open(u) } } label: { Label("Open listing", systemImage: "safari") }
                    .buttonStyle(SoftButton())
                Button(expanded ? "Hide details" : "Details") { withAnimation(.smooth) { expanded.toggle() } }
                    .buttonStyle(SoftButton())
                Spacer()
                Button("Mark as applied") {
                    withAnimation(.smooth) { store.recordSubmission(job, shared: [], method: "Marked manually") }
                }.buttonStyle(SoftButton())
                Button("Dismiss") { withAnimation(.smooth) { store.dismiss(job) } }
                    .buttonStyle(SoftButton())
            }
            .padding(.top, 2)
        }
        .card()
    }
}

// MARK: - Candidate info

struct InfoTab: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @State private var busy = false
    @State private var note = ""

    var body: some View {
        TabPage {
            PageHeader(title: "Candidate Info", subtitle: "What the AI knows about you. It draws on this to fill in applications.") { EmptyView() }

            HStack(spacing: 14) {
                Image(systemName: "doc.fill").font(.system(size: 22)).foregroundStyle(Color.crimson)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Résumé").font(.system(size: 13, weight: .semibold))
                    Text(note.isEmpty ? (store.data.resumeFile ?? "No résumé added") : note)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if store.data.resumeFile != nil {
                    Button("Re-read details") { Task { await extract(overwrite: false) } }.buttonStyle(SoftButton()).disabled(busy)
                    Button("Remove") { ResumeImporter.remove(store: store); note = "" }.buttonStyle(SoftButton())
                }
                Button(store.data.resumeFile == nil ? "Add PDF…" : "Replace…") {
                    guard let url = chooseResumePDF() else { return }
                    if ResumeImporter.attach(url, store: store) { Task { await extract(overwrite: false) } }
                    else { note = "That file could not be read as a PDF." }
                }.buttonStyle(PrimaryButton()).disabled(busy)
            }
            .card()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label2("Details")
                    Spacer()
                    Text("Answers you type during an application are saved here automatically.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                ForEach($store.data.info) { $f in
                    HStack(alignment: .top, spacing: 8) {
                        TextField("Field name", text: $f.key).input().frame(width: 210)
                        TextField("Value", text: $f.value, axis: .vertical).lineLimit(1...6).input()
                        IconButton(symbol: "trash", help: "Delete field") {
                            withAnimation(.smooth) { store.data.info.removeAll { $0.id == f.id } }
                        }
                    }
                    .transition(.opacity)
                }
                Button {
                    withAnimation(.smooth) { store.data.info.append(InfoField(key: "", value: "")) }
                } label: { Label("Add field", systemImage: "plus") }
                    .buttonStyle(SoftButton()).padding(.top, 4)
            }
            .card()
        }
    }

    private func extract(overwrite: Bool) async {
        busy = true
        note = "Reading résumé…"
        let problem = await ResumeImporter.extract(store: store, ai: app.ai, overwrite: overwrite)
        busy = false
        note = problem.map { "Could not extract details: \($0)" } ?? ""
    }
}

// MARK: - Previously submitted

struct SubmittedTab: View {
    @EnvironmentObject var store: Store

    var body: some View {
        TabPage {
            PageHeader(title: "Previously Submitted", subtitle: "Applications sent through JobPilot. Search never revisits these listings.") {
                if !store.data.submissions.isEmpty { Pill(text: "\(store.data.submissions.count) total") }
            }
            if store.data.submissions.isEmpty {
                EmptyState(symbol: "checkmark.seal", title: "Nothing submitted yet",
                           message: "Applications you send appear here with the date and the information that was shared.")
            } else {
                ForEach(store.data.submissions) { s in SubmissionCard(item: s) }
            }
        }
    }
}

struct SubmissionCard: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    let item: Submission
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.job.title).font(.system(size: 15, weight: .semibold))
                    Text([item.job.company, item.job.location].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12.5, weight: .medium))
                    Pill(text: item.method, color: item.method == "Autofill" ? .crimson : .secondary, solid: item.method == "Autofill")
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Label2("Information shared")
                    if item.shared.isEmpty {
                        Text("No field data was recorded (this application was marked as applied by hand).")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    } else {
                        ForEach(item.shared) { f in
                            HStack(alignment: .top, spacing: 12) {
                                Text(f.label).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(width: 220, alignment: .leading)
                                Text(f.value).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity)
            }
            HStack(spacing: 8) {
                Button(expanded ? "Hide shared info" : "View shared info") { withAnimation(.smooth) { expanded.toggle() } }
                    .buttonStyle(SoftButton())
                Button { if let u = URL(string: item.job.url) { NSWorkspace.shared.open(u) } } label: { Label("Open listing", systemImage: "safari") }
                    .buttonStyle(SoftButton())
                Spacer()
                Button("Remove record") {
                    app.ask(DialogSpec(title: "Remove this record?",
                                       message: "The application itself is not withdrawn. Search will still skip this listing.",
                                       confirm: "Remove", destructive: true) {
                        withAnimation(.smooth) { store.data.submissions.removeAll { $0.id == item.id } }
                    })
                }.buttonStyle(SoftButton())
            }
        }
        .card()
    }
}

// MARK: - Apply workspace (in-app browser + AI form filler)

struct ApplyView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var session: AutofillSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.job.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(session.job.company).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Close") { app.closeSession() }.buttonStyle(SoftButton()).keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 84).padding(.trailing, 12).frame(height: 46)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        IconButton(symbol: "chevron.left", help: "Back") { session.web.goBack() }
                        IconButton(symbol: "arrow.clockwise", help: "Reload") { session.web.reload() }
                        Text(session.address).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Color.subtle, in: RoundedRectangle(cornerRadius: 6))
                        if session.pageLoading { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                    WebContainer(web: session.web)
                }
                Divider()
                panel.frame(width: 360)
            }
        }
        .background(Color.bg)
    }

    private var busy: Bool { session.phase == .scanning || session.phase == .thinking || session.phase == .loading }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(phaseText).font(.system(size: 13, weight: .semibold))
                }
                if !session.note.isEmpty {
                    Text(session.note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !session.missingRequired.isEmpty {
                    Label("\(session.missingRequired.count) required field\(session.missingRequired.count == 1 ? "" : "s") need your input",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.crimson)
                }
                if !session.drafts.isEmpty {
                    Label("\(session.drafts.count) AI-written answer\(session.drafts.count == 1 ? "" : "s") to review",
                          systemImage: "pencil.and.outline")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                }
            }
            .padding(14)
            .animation(.smooth, value: session.phase)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sorted) { f in FieldRow(session: session, field: f) }
                }
                .padding(14)
            }
            Divider()
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button { Task { await session.scanAndFill() } } label: { Label("Scan & Autofill", systemImage: "wand.and.stars") }
                        .buttonStyle(SoftButton()).disabled(busy)
                    Button("Update page") { Task { await session.pushToPage() } }
                        .buttonStyle(SoftButton()).disabled(busy || session.fields.isEmpty)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button("Record as submitted") {
                        session.record()
                        app.closeSession()
                        withAnimation(.smooth) { app.tab = .submitted }
                    }
                    .buttonStyle(session.phase == .submitted ? AnyButtonStyle(PrimaryButton()) : AnyButtonStyle(SoftButton()))
                    Spacer()
                    if session.phase != .submitted {
                        Button("Submit application") { confirmSubmit() }
                            .buttonStyle(PrimaryButton()).disabled(busy || session.fields.isEmpty)
                    }
                }
            }
            .padding(12)
        }
        .background(Color.card.opacity(0.5))
    }

    /// Fields that need the user come first.
    private var sorted: [FormField] {
        session.fields.filter(\.needsAttention) + session.fields.filter { !$0.needsAttention && $0.status == .draft }
            + session.fields.filter { !$0.needsAttention && $0.status != .draft }
    }

    private var phaseText: String {
        switch session.phase {
        case .loading: return "Loading listing…"
        case .idle: return "Ready to scan"
        case .scanning: return "Reading the form…"
        case .thinking: return "AI is filling in your answers…"
        case .ready: return session.missingRequired.isEmpty ? "Filled in. Review, then submit." : "Almost there"
        case .submitted: return "Submit pressed"
        }
    }

    private func confirmSubmit() {
        let missing = session.missingRequired.count
        app.ask(DialogSpec(
            title: "Submit this application?",
            message: (missing > 0 ? "\(missing) required field\(missing == 1 ? " is" : "s are") still empty, so the site may reject it. " : "")
                + "JobPilot will apply your answers and press the page's submit button for \(session.job.title) at \(session.job.company).",
            confirm: "Submit") { Task { _ = await session.submit() } })
    }
}

struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct FieldRow: View {
    @ObservedObject var session: AutofillSession
    let field: FormField

    private var value: Binding<String> {
        Binding(get: { field.value }, set: { session.edit(field.id, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(field.label).font(.system(size: 12, weight: .medium)).lineLimit(2)
                if field.required { Text("Required").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                tag
            }
            editor
        }
        .padding(10)
        .background(field.needsAttention ? Color.crimson.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(field.needsAttention ? Color.crimson.opacity(0.6) : Color.line, lineWidth: field.needsAttention ? 1 : 0.5))
    }

    @ViewBuilder private var tag: some View {
        if field.needsAttention { Pill(text: "Needs input", color: .crimson, solid: true) }
        else if field.status == .draft { Pill(text: "AI draft", color: .orange) }
        else if field.status == .user { Pill(text: "Yours · saved", color: .secondary) }
        else if field.status == .filled { Pill(text: "Filled", color: .green) }
    }

    @ViewBuilder private var editor: some View {
        switch field.type {
        case "file":
            Text(field.value == "__RESUME__" ? "Your résumé PDF will be attached"
                 : (field.value.isEmpty ? "No file. Attach one in the page if needed." : field.value))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        case "select", "radio":
            Picker("", selection: value) {
                Text("Not answered").tag("")
                ForEach(Array(field.options.enumerated()), id: \.offset) { _, o in Text(o).tag(o) }
                if !field.value.isEmpty && !field.options.contains(field.value) { Text(field.value).tag(field.value) }
            }
            .labelsHidden().pickerStyle(.menu)
        case "checkbox":
            Toggle("Checked", isOn: Binding(get: { field.value == "Yes" }, set: { session.edit(field.id, $0 ? "Yes" : "No") }))
                .toggleStyle(.checkbox).font(.system(size: 12))
        case "checkboxes":
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(field.options.enumerated()), id: \.offset) { _, o in
                    Toggle(o, isOn: Binding(
                        get: { chosen.contains(o) },
                        set: { on in
                            var c = chosen.filter { $0 != o }
                            if on { c.append(o) }
                            session.edit(field.id, c.joined(separator: " | "))
                        }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
                }
            }
        case "textarea":
            TextField("Your answer", text: value, axis: .vertical).lineLimit(2...9).input()
        default:
            TextField("Your answer", text: value).input()
        }
    }

    private var chosen: [String] { field.value.components(separatedBy: "|").map(\.trimmed).filter { !$0.isEmpty } }
}
