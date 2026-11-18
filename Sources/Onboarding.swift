import SwiftUI
import UniformTypeIdentifiers

@MainActor
func chooseResumePDF() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = false
    panel.message = "Choose your résumé (PDF)"
    return panel.runModal() == .OK ? panel.url : nil
}

struct OnboardingView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store

    @State private var step = 0
    @State private var forward = true
    @State private var appeared = false

    // AI step
    @State private var claudeKey = ""
    @State private var ollamaKey = ""
    @State private var aiStatus = ""
    @State private var aiOK = false
    @State private var aiBusy = false
    // Résumé step
    @State private var reading = false
    @State private var resumeNote = ""
    @State private var dropTarget = false

    private let titles = ["Welcome", "AI model", "Résumé", "Your details", "Job search", "All set"]

    var body: some View {
        VStack(spacing: 0) {
            // Progress
            HStack(spacing: 6) {
                ForEach(0..<titles.count, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Color.crimson : Color.primary.opacity(0.12))
                        .frame(width: i == step ? 34 : 14, height: 5)
                }
            }
            .animation(.smooth, value: step)
            .padding(.top, 54)

            ZStack {
                content
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: 560, maxHeight: .infinity)
            .clipped()

            // Navigation
            HStack {
                if step > 0 {
                    Button("Back") { go(step - 1) }.buttonStyle(SoftButton())
                }
                Spacer()
                if step > 0 && step < titles.count - 1 {
                    Button("Skip for now") { go(step + 1) }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                }
                Button(step == 0 ? "Get started" : (step == titles.count - 1 ? "Open JobPilot" : "Continue")) { advance() }
                    .buttonStyle(PrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(reading || aiBusy)
            }
            .frame(maxWidth: 560)
            .padding(.bottom, 36)
        }
        .padding(.horizontal, 40)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .onAppear {
            claudeKey = Keychain.get("claude")
            withAnimation(.easeOut(duration: 0.6)) { appeared = true }
        }
    }

    private func go(_ to: Int) {
        forward = to > step
        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { step = to }
    }

    private func advance() {
        switch step {
        case 1:
            // Keep whatever was typed even if the user did not press Connect.
            if store.data.ai.provider == .claude { Keychain.set("claude", claudeKey) } else { Keychain.set("ollama", ollamaKey) }
            go(2)
        case titles.count - 1:
            withAnimation(.easeInOut(duration: 0.5)) { store.data.onboarded = true }
        default:
            go(step + 1)
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcome
        case 1: aiStep
        case 2: resumeStep
        case 3: detailsStep
        case 4: preferencesStep
        default: doneStep
        }
    }

    private func heading(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 28, weight: .bold))
            Text(sub).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "briefcase.fill")
                .font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 92, height: 92)
                .background(LinearGradient(colors: [Color.crimson, Color.crimson.opacity(0.75)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Color.crimson.opacity(0.35), radius: 18, y: 8)
            Text("Welcome to JobPilot").font(.system(size: 30, weight: .bold))
            Text("JobPilot finds job listings that suit you, fills in the applications with AI, and keeps track of everything you send. Setup takes about two minutes, and every step can be skipped and finished later.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
        }
    }

    private var aiStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Choose your AI model", "It reads your résumé, judges listings and fills in applications. You can change this any time from the top-right menu.")
            HStack(spacing: 12) {
                ForEach(ProviderID.allCases) { p in
                    let on = store.data.ai.provider == p
                    Button {
                        withAnimation(.smooth) { store.data.ai.provider = p; aiStatus = "" }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: p.symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 30, height: 30).background(on ? Color.crimson : Color.secondary.opacity(0.6), in: Circle())
                            Text(p.title).font(.system(size: 15, weight: .semibold))
                            Text(p.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(on ? Color.crimson : Color.line, lineWidth: on ? 1.5 : 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if store.data.ai.provider == .claude {
                    Label2("Claude API key")
                    SecureField("sk-ant-…", text: $claudeKey).input()
                    Text("Create a key at console.anthropic.com. It is stored in your Mac's Keychain.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    Label2("Ollama server")
                    TextField("http://localhost:11434", text: $store.data.ai.ollama.baseURL).input()
                    SecureField("API key (optional)", text: $ollamaKey).input()
                    Text("Install Ollama from ollama.com and pull a model (for example: ollama pull llama3.2).")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button(aiBusy ? "Connecting…" : "Connect") { Task { await connect() } }
                        .buttonStyle(SoftButton()).disabled(aiBusy)
                    if !aiStatus.isEmpty {
                        Label(aiStatus, systemImage: aiOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(aiOK ? Color.green : Color.crimson)
                            .transition(.opacity.combined(with: .offset(x: -6)))
                    }
                }
                .padding(.top, 4)
            }
            .card()
        }
    }

    private func connect() async {
        aiBusy = true
        defer { aiBusy = false }
        do {
            if store.data.ai.provider == .claude {
                guard !claudeKey.trimmed.isEmpty else { throw AIError(message: "Enter an API key first.") }
                try await AIService.testClaude(key: claudeKey.trimmed)
                Keychain.set("claude", claudeKey)
                withAnimation(.smooth) { aiStatus = "Connected to Claude"; aiOK = true }
            } else {
                let models = try await AIService.ollamaModels(base: store.data.ai.ollama.baseURL, key: ollamaKey.trimmed)
                Keychain.set("ollama", ollamaKey)
                guard let first = models.first else { throw AIError(message: "Connected, but no models are installed yet.") }
                if store.data.ai.ollama.model.isEmpty { store.data.ai.ollama.model = first }
                withAnimation(.smooth) { aiStatus = "Connected · using \(store.data.ai.ollama.model)"; aiOK = true }
            }
        } catch {
            withAnimation(.smooth) { aiStatus = error.localizedDescription; aiOK = false }
        }
    }

    private var resumeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Add your résumé", "JobPilot reads it to fill in your details and attaches it to applications that ask for one.")
            VStack(spacing: 12) {
                if reading {
                    ProgressView().controlSize(.large)
                    Text("Reading your résumé…").font(.system(size: 13)).foregroundStyle(.secondary)
                } else if let name = store.data.resumeFile {
                    Image(systemName: "doc.fill").font(.system(size: 30)).foregroundStyle(Color.crimson)
                    Text(name).font(.system(size: 14, weight: .semibold))
                    Button("Choose a different file") { pickResume() }.buttonStyle(SoftButton())
                } else {
                    Image(systemName: "arrow.down.doc").font(.system(size: 30, weight: .light)).foregroundStyle(Color.crimson)
                    Text("Drop a PDF here").font(.system(size: 14, weight: .semibold))
                    Button("Choose file…") { pickResume() }.buttonStyle(SoftButton())
                }
                if !resumeNote.isEmpty {
                    Text(resumeNote).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 210)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(dropTarget ? Color.crimson : Color.line, style: StrokeStyle(lineWidth: dropTarget ? 2 : 1, dash: [6, 5])))
            .scaleEffect(dropTarget ? 1.015 : 1)
            .animation(.smooth, value: dropTarget)
            .animation(.smooth, value: reading)
            .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in await importResume(url) } }
                }
                return true
            }
        }
    }

    private func pickResume() {
        if let url = chooseResumePDF() { Task { await importResume(url) } }
    }

    private func importResume(_ url: URL) async {
        guard url.pathExtension.lowercased() == "pdf", ResumeImporter.attach(url, store: store) else {
            resumeNote = "That file could not be read as a PDF."
            return
        }
        reading = true
        resumeNote = ""
        let problem = await ResumeImporter.extract(store: store, ai: app.ai, overwrite: true)
        reading = false
        if let problem {
            resumeNote = "Saved, but details could not be extracted automatically: \(problem)"
        } else if !app.ai.isReady(.resume) {
            resumeNote = "Saved. No AI model is connected yet, so only email and phone were detected."
            go(3)
        } else {
            go(3)
        }
    }

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Check your details", store.data.resumeFile == nil
                    ? "These are used to fill in applications. Add what you like now; the rest can wait."
                    : "Here is what was found in your résumé. Correct anything that is wrong.")
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($store.data.info) { $f in
                        HStack(spacing: 8) {
                            TextField("Field", text: $f.key).input().frame(width: 160)
                            TextField("Value", text: $f.value, axis: .vertical).lineLimit(1...4).input()
                            IconButton(symbol: "minus.circle", help: "Remove") {
                                withAnimation(.smooth) { store.data.info.removeAll { $0.id == f.id } }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    Button {
                        withAnimation(.smooth) { store.data.info.append(InfoField(key: "", value: "")) }
                    } label: { Label("Add field", systemImage: "plus") }
                        .buttonStyle(SoftButton()).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(2)
            }
            .frame(maxHeight: 330)
        }
    }

    private var preferencesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("What are you looking for?", "Describe the jobs you want in your own words: roles, level, location or remote, industries, pay, anything to avoid. The AI uses this to decide which listings are worth your time.")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.data.preferences)
                    .font(.system(size: 13.5)).scrollContentBackground(.hidden).padding(8)
                if store.data.preferences.isEmpty {
                    Text("e.g. Entry-level product design roles in New York or remote, at companies under 500 people. Not interested in agencies or unpaid internships.")
                        .font(.system(size: 13.5)).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 170)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.line, lineWidth: 0.5))
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 62)).foregroundStyle(Color.crimson)
                .symbolEffect(.bounce, value: step)
            Text("You're all set").font(.system(size: 28, weight: .bold))
            VStack(alignment: .leading, spacing: 8) {
                summaryRow("AI model", app.ai.isReady(store.data.ai.provider) ? store.data.ai.modelLabel(store.data.ai.provider) : "Not connected yet")
                summaryRow("Résumé", store.data.resumeFile ?? "Not added yet")
                summaryRow("Details", "\(store.data.info.filter { !$0.value.isEmpty }.count) saved")
                summaryRow("Job search", store.data.preferences.trimmed.isEmpty ? "Not described yet" : "Described")
            }
            .card().frame(maxWidth: 380)
            Text("Anything you skipped can be filled in from the app's tabs.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
    }

    private func summaryRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
    }
}
