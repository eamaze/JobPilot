import SwiftUI
import WebKit

enum Tab: String, CaseIterable, Identifiable {
    case search, results, info, submitted
    var id: String { rawValue }
    var title: String {
        switch self {
        case .search: return "Search"
        case .results: return "Results"
        case .info: return "Candidate Info"
        case .submitted: return "Previously Submitted"
        }
    }
    var symbol: String {
        switch self {
        case .search: return "magnifyingglass"
        case .results: return "sparkles.rectangle.stack"
        case .info: return "person.text.rectangle"
        case .submitted: return "checkmark.seal"
        }
    }
}

struct DialogSpec {
    var title: String
    var message: String
    var confirm: String
    var destructive = false
    var action: () -> Void
}

/// In-app browser used for signing in to job sites; shares cookies with search and autofill.
@MainActor
final class BrowserSession: NSObject, ObservableObject, WKUIDelegate {
    let title: String
    let web: WKWebView
    init(title: String, url: String) {
        self.title = title
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        super.init()
        web.uiDelegate = self
        if let u = URL(string: url) { web.load(URLRequest(url: u)) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var tab: Tab = .search
    @Published var sidebarCollapsed = false
    @Published var showSettings = false
    @Published var showAI = false
    @Published var dialog: DialogSpec?
    @Published var session: AutofillSession?
    @Published var browser: BrowserSession?

    let store: Store
    let ai: AIService
    let engine: SearchEngine

    init() {
        store = Store()
        ai = AIService(store: store)
        engine = SearchEngine(store: store, ai: ai)
    }

    func applyTheme() {
        switch store.data.theme {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    func ask(_ spec: DialogSpec) { withAnimation(.smooth) { dialog = spec } }

    func apply(to job: Job) {
        withAnimation(.smooth) { session = AutofillSession(job: job, store: store, ai: ai) }
    }

    func closeSession() {
        session?.close()
        withAnimation(.smooth) { session = nil }
    }

    func resetEverything() {
        engine.setEnabled(false)
        session?.close()
        withAnimation(.smooth) {
            session = nil; browser = nil; showSettings = false; showAI = false; tab = .search
            store.reset()
        }
        applyTheme()
    }
}

@main
struct JobPilotApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.store)
                .environmentObject(app.engine)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { app.applyTheme() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            if store.data.onboarded {
                MainView().transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else {
                OnboardingView().transition(.opacity)
            }

            if app.showAI {
                Color.black.opacity(0.001).ignoresSafeArea()
                    .onTapGesture { withAnimation(.smooth) { app.showAI = false } }
                AIMenu()
                    .padding(.top, 44).padding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                    .zIndex(2)
            }
            if app.showSettings {
                Popup(dismiss: { withAnimation(.smooth) { app.showSettings = false } }) { SettingsView() }.zIndex(3)
            }
            if let session = app.session {
                ApplyView(session: session)
                    .transition(.move(edge: .bottom).combined(with: .opacity)).zIndex(4)
            }
            if let browser = app.browser {
                Popup(dismiss: nil) { BrowserView(browser: browser) }.zIndex(5)
            }
            if let d = app.dialog {
                Popup(dismiss: { withAnimation(.smooth) { app.dialog = nil } }) { DialogView(spec: d) }.zIndex(6)
            }
        }
        .ignoresSafeArea()
        .tint(.crimson)
        .onChange(of: store.data.theme) { _, _ in app.applyTheme() }
    }
}

// MARK: - Main shell

struct MainView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider()
            HStack(spacing: 0) {
                Sidebar()
                Divider()
                Group {
                    switch app.tab {
                    case .search: SearchTab()
                    case .results: ResultsTab()
                    case .info: InfoTab()
                    case .submitted: SubmittedTab()
                    }
                }
                .id(app.tab)
                .transition(.opacity.combined(with: .offset(y: 6)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store

    var body: some View {
        ZStack {
            Text("JobPilot").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Spacer().frame(width: 74)   // room for the window's traffic lights
                IconButton(symbol: "gearshape", help: "Settings") {
                    withAnimation(.smooth) { app.showSettings = true; app.showAI = false }
                }
                IconButton(symbol: "sidebar.left", help: "Toggle sidebar") {
                    withAnimation(.smooth) { app.sidebarCollapsed.toggle() }
                }
                Spacer()
                Button {
                    withAnimation(.smooth) { app.showAI.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: store.data.ai.provider.symbol)
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Color.crimson, in: Circle())
                        Text(store.data.ai.modelLabel(store.data.ai.provider)).font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(app.showAI ? 180 : 0))
                    }
                    .padding(.leading, 4).padding(.trailing, 9).padding(.vertical, 3)
                    .background(Color.subtle, in: Capsule())
                    .overlay(Capsule().stroke(Color.line, lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("AI model")
            }
            .padding(.trailing, 12)
        }
        .frame(height: 38)
        .background(Color.card.opacity(0.6))
    }
}

struct Sidebar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @EnvironmentObject var engine: SearchEngine

    var body: some View {
        let collapsed = app.sidebarCollapsed
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Tab.allCases) { tab in
                SidebarItem(tab: tab, collapsed: collapsed,
                            badge: tab == .results ? store.data.results.count : 0)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(engine.enabled ? Color.crimson : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .opacity(engine.working ? 0.35 : 1)
                    .animation(engine.working ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: engine.working)
                if !collapsed {
                    Text(engine.enabled ? (engine.working ? "Searching…" : "Search on") : "Search off")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, collapsed ? 18 : 12).padding(.bottom, 12)
        }
        .padding(.top, 10).padding(.horizontal, 8)
        .frame(width: collapsed ? 60 : 216, alignment: .leading)
        .background(Color.card.opacity(0.45))
    }
}

struct SidebarItem: View {
    @EnvironmentObject var app: AppState
    let tab: Tab
    let collapsed: Bool
    let badge: Int
    @State private var hover = false

    var body: some View {
        let on = app.tab == tab
        Button {
            withAnimation(.smooth) { app.tab = tab }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(on ? Color.crimson : Color.secondary)
                    .frame(width: 22)
                if !collapsed {
                    Text(tab.title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 0)
                    if badge > 0 {
                        Text("\(badge)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1.5).background(Color.crimson, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(on ? 0.09 : (hover ? 0.045 : 0)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if collapsed && badge > 0 { Circle().fill(Color.crimson).frame(width: 7, height: 7).offset(x: -6, y: 6) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tab.title)
    }
}

// MARK: - Pop-ups

struct DialogView: View {
    @EnvironmentObject var app: AppState
    let spec: DialogSpec
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: spec.destructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 20)).foregroundStyle(Color.crimson)
                Text(spec.title).font(.system(size: 16, weight: .semibold))
            }
            Text(spec.message).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { withAnimation(.smooth) { app.dialog = nil } }
                    .buttonStyle(SoftButton()).keyboardShortcut(.cancelAction)
                Button(spec.confirm) {
                    withAnimation(.smooth) { app.dialog = nil }
                    spec.action()
                }
                .buttonStyle(PrimaryButton())
            }
            .padding(.top, 6)
        }
        .padding(22).frame(width: 400)
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Settings").font(.system(size: 18, weight: .bold))
                Spacer()
                IconButton(symbol: "xmark", help: "Close") { withAnimation(.smooth) { app.showSettings = false } }
            }
            VStack(alignment: .leading, spacing: 8) {
                Label2("Appearance")
                Seg(options: [("System", "system"), ("Light", "light"), ("Dark", "dark")], selection: $store.data.theme)
                Text("Crimson stays the accent colour in every theme.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label2("Data")
                Text("Everything is stored on this Mac in Application Support. API keys are kept in your Keychain.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    app.ask(DialogSpec(title: "Reset JobPilot?",
                                       message: "This permanently deletes your candidate info, résumé, results, submission history, saved API keys and site sign-ins, then restarts onboarding. It cannot be undone.",
                                       confirm: "Delete everything", destructive: true) { app.resetEverything() })
                } label: {
                    Label("Reset app and delete all data", systemImage: "trash")
                }
                .buttonStyle(SoftButton(tint: .crimson))
            }
        }
        .padding(22).frame(width: 420)
    }
}

struct BrowserView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var browser: BrowserSession
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(browser.title).font(.system(size: 14, weight: .semibold))
                Text("Sign in here once; search and autofill reuse the session.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { withAnimation(.smooth) { app.browser = nil } }.buttonStyle(PrimaryButton())
            }
            .padding(12)
            Divider()
            WebContainer(web: browser.web)
        }
        .frame(width: 860, height: 600)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - AI menu (top-right dropdown)

struct AIMenu: View {
    @EnvironmentObject var store: Store
    @State private var claudeKey = Keychain.get("claude")
    @State private var ollamaKey = Keychain.get("ollama")
    @State private var ollamaModels: [String] = []
    @State private var status = ""
    @State private var statusOK = false
    @State private var busy = false

    var body: some View {
        let provider = store.data.ai.provider
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label2("Provider")
                    ForEach(ProviderID.allCases) { p in
                        MenuRow(symbol: p.symbol, title: p.title, note: p.subtitle, on: provider == p) {
                            withAnimation(.smooth) { store.data.ai.provider = p; status = "" }
                            if p == .ollama { Task { await loadOllama() } }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label2("Model")
                    if provider == .claude {
                        ForEach(ClaudeModel.all) { m in
                            MenuRow(symbol: nil, title: m.name, note: m.note, on: store.data.ai.claude.model == m.id) {
                                withAnimation(.smooth) { store.data.ai.claude.model = m.id }
                            }
                        }
                    } else {
                        if ollamaModels.isEmpty {
                            TextField("Model name, e.g. llama3.2", text: $store.data.ai.ollama.model).input()
                        } else {
                            ForEach(ollamaModels, id: \.self) { m in
                                MenuRow(symbol: nil, title: m, note: "", on: store.data.ai.ollama.model == m) {
                                    withAnimation(.smooth) { store.data.ai.ollama.model = m }
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label2("Model settings")
                    if provider == .claude {
                        Text("Effort").font(.system(size: 12, weight: .medium))
                        Seg(options: [("Low", "low"), ("Med", "medium"), ("High", "high"), ("XHigh", "xhigh"), ("Max", "max")],
                            selection: $store.data.ai.claude.effort)
                        Text("Higher effort thinks longer: better answers, slower and costlier.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("Temperature").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(String(format: "%.1f", store.data.ai.ollama.temperature)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Slider(value: $store.data.ai.ollama.temperature, in: 0...1, step: 0.1)
                        Text("Server address").font(.system(size: 12, weight: .medium))
                        TextField("http://localhost:11434", text: $store.data.ai.ollama.baseURL).input()
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label2("Authentication")
                    if provider == .claude {
                        SecureField("Claude API key (sk-ant-…)", text: $claudeKey).input()
                    } else {
                        SecureField("API key (optional, for hosted Ollama)", text: $ollamaKey).input()
                    }
                    HStack(spacing: 8) {
                        Button(busy ? "Checking…" : "Save & test") { Task { await saveAndTest() } }
                            .buttonStyle(SoftButton()).disabled(busy)
                        if !status.isEmpty {
                            Label(status, systemImage: statusOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .font(.system(size: 11.5)).foregroundStyle(statusOK ? Color.green : Color.crimson).lineLimit(2)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Label2("Model per feature")
                    ForEach(AIFeature.allCases) { f in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(f.title).font(.system(size: 12, weight: .medium))
                            Seg(options: [("Default", ""), ("Claude", "claude"), ("Ollama", "ollama")], selection: Binding(
                                get: { store.data.ai.featureOverrides[f.rawValue]?.rawValue ?? "" },
                                set: { store.data.ai.featureOverrides[f.rawValue] = ProviderID(rawValue: $0) }))
                        }
                    }
                    Text("Each feature uses the provider chosen here, with that provider's model and settings above.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .frame(width: 340)
        .frame(maxHeight: 620)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .task { if provider == .ollama { await loadOllama() } }
    }

    private func loadOllama() async {
        ollamaModels = (try? await AIService.ollamaModels(base: store.data.ai.ollama.baseURL, key: ollamaKey)) ?? []
        if store.data.ai.ollama.model.isEmpty, let first = ollamaModels.first { store.data.ai.ollama.model = first }
    }

    private func saveAndTest() async {
        busy = true
        defer { busy = false }
        do {
            if store.data.ai.provider == .claude {
                Keychain.set("claude", claudeKey)
                guard !claudeKey.trimmed.isEmpty else { status = "Key removed"; statusOK = false; return }
                try await AIService.testClaude(key: claudeKey.trimmed)
                status = "Connected"
            } else {
                Keychain.set("ollama", ollamaKey)
                let models = try await AIService.ollamaModels(base: store.data.ai.ollama.baseURL, key: ollamaKey.trimmed)
                ollamaModels = models
                if store.data.ai.ollama.model.isEmpty, let first = models.first { store.data.ai.ollama.model = first }
                status = models.isEmpty ? "Connected, but no models are installed" : "Connected · \(models.count) models"
            }
            statusOK = true
        } catch {
            status = error.localizedDescription
            statusOK = false
        }
    }
}

struct MenuRow: View {
    let symbol: String?
    let title: String
    let note: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(on ? Color.crimson : Color.secondary.opacity(0.6), in: Circle())
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: on ? .semibold : .regular))
                    if !note.isEmpty { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer()
                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.crimson) }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color.primary.opacity(on ? 0.07 : (hover ? 0.04 : 0)), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
