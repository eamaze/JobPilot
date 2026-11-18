import Foundation
import Security
import WebKit

// MARK: - Data model

struct InfoField: Codable, Identifiable, Equatable {
    var id = UUID()
    var key: String
    var value: String
}

struct Job: Codable, Identifiable, Equatable {
    var id: String            // normalised URL, used for de-duplication
    var title: String
    var company: String
    var location: String
    var url: String
    var source: String
    var description: String
    var score: Int = 0
    var reason: String = ""
    var foundAt = Date()

    /// Second de-duplication key, so the same posting found on two boards is only kept once.
    var signature: String { "sig:" + (title + "|" + company).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "|" } }
}

struct SharedField: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var value: String
}

struct Submission: Codable, Identifiable {
    var id = UUID()
    var job: Job
    var date: Date
    var shared: [SharedField]
    var method: String        // "Autofill" or "Marked manually"
}

enum ProviderID: String, Codable, CaseIterable, Identifiable {
    case claude, ollama
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Ollama" }
    var subtitle: String { self == .claude ? "Anthropic API · needs an API key" : "Local models · runs on your Mac" }
    var symbol: String { self == .claude ? "asterisk" : "pawprint.fill" }
}

enum AIFeature: String, Codable, CaseIterable, Identifiable {
    case resume, matching, autofill
    var id: String { rawValue }
    var title: String {
        switch self {
        case .resume: return "Résumé reading"
        case .matching: return "Job matching"
        case .autofill: return "Autofill"
        }
    }
}

struct ClaudeModel: Identifiable {
    let id: String, name: String, note: String
    static let all = [
        ClaudeModel(id: "claude-fable-5-2", name: "Claude Fable 5.2", note: "Most capable"),
        ClaudeModel(id: "claude-opus-5-5", name: "Claude Opus 5.5", note: "Recommended"),
        ClaudeModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", note: "Fast, lower cost"),
        ClaudeModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", note: "Fastest, cheapest"),
    ]
    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
}

struct ClaudeSettings: Codable {
    var model = "claude-opus-5-5"
    var effort = "medium"
}

struct OllamaSettings: Codable {
    var baseURL = "http://localhost:11434"
    var model = ""
    var temperature = 0.2
}

struct AISettings: Codable {
    var provider: ProviderID = .claude
    var claude = ClaudeSettings()
    var ollama = OllamaSettings()
    var featureOverrides: [String: ProviderID] = [:]   // AIFeature.rawValue → provider; absent = default

    func provider(for feature: AIFeature) -> ProviderID { featureOverrides[feature.rawValue] ?? provider }
    func modelLabel(_ p: ProviderID) -> String {
        p == .claude ? ClaudeModel.name(claude.model) : (ollama.model.isEmpty ? "Ollama" : ollama.model)
    }
}

struct SearchSettings: Codable {
    var sources: [String: Bool] = ["linkedin": true, "remotive": true, "arbeitnow": true, "web": true, "handshake": false, "custom": true]
    var intervalMinutes = 30
    var customURLs: [String] = []
    var location = ""
    var minScore = 70
}

struct AppData: Codable {
    var onboarded = false
    var theme = "system"
    var ai = AISettings()
    var info: [InfoField] = AppData.baseKeys.map { InfoField(key: $0, value: "") }
    var resumeFile: String?
    var resumeText = ""
    var preferences = ""
    var search = SearchSettings()
    var results: [Job] = []
    var submissions: [Submission] = []
    var seen: [String: String] = [:]      // job id / signature → why it will not be looked at again

    static let baseKeys = ["Full Name", "Email", "Phone", "Location"]
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var data: AppData { didSet { scheduleSave() } }
    private var saveTask: Task<Void, Never>?

    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("JobPilot", isDirectory: true)
        // Lets tests run against a throwaway folder instead of the user's data.
        if let o = ProcessInfo.processInfo.environment["JOBPILOT_DATA_DIR"] { d = URL(fileURLWithPath: o, isDirectory: true) }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static var file: URL { dir.appendingPathComponent("data.json") }
    static var resumeURL: URL { dir.appendingPathComponent("resume.pdf") }

    init() {
        if let raw = try? Data(contentsOf: Store.file), let d = try? Store.decoder.decode(AppData.self, from: raw) {
            data = d
        } else {
            data = AppData()
        }
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        if let raw = try? Store.encoder.encode(data) { try? raw.write(to: Store.file, options: .atomic) }
    }

    // Candidate info

    func infoValue(_ key: String) -> String {
        data.info.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value ?? ""
    }

    func upsertInfo(key: String, value: String, overwrite: Bool = true) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !v.isEmpty else { return }
        if let i = data.info.firstIndex(where: { $0.key.caseInsensitiveCompare(k) == .orderedSame }) {
            if overwrite || data.info[i].value.isEmpty { data.info[i].value = v }
        } else {
            data.info.append(InfoField(key: k, value: v))
        }
    }

    var candidateSummary: String {
        data.info.filter { !$0.value.trimmed.isEmpty && !$0.key.trimmed.isEmpty }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    // Jobs

    func isKnown(_ job: Job) -> Bool {
        if data.seen[job.id] != nil || data.seen[job.signature] != nil { return true }
        if data.results.contains(where: { $0.id == job.id || $0.signature == job.signature }) { return true }
        return data.submissions.contains { $0.job.id == job.id || $0.job.signature == job.signature }
    }

    func markSeen(_ job: Job, _ why: String) {
        data.seen[job.id] = why
        data.seen[job.signature] = why
    }

    func dismiss(_ job: Job) {
        markSeen(job, "dismissed")
        data.results.removeAll { $0.id == job.id }
    }

    func recordSubmission(_ job: Job, shared: [SharedField], method: String) {
        data.submissions.insert(Submission(job: job, date: Date(), shared: shared, method: method), at: 0)
        data.results.removeAll { $0.id == job.id }
        markSeen(job, "submitted")
    }

    /// Deletes every trace of the user's data and returns the app to onboarding.
    func reset() {
        saveTask?.cancel()
        for p in ProviderID.allCases { Keychain.delete(p.rawValue) }
        try? FileManager.default.removeItem(at: Store.resumeURL)
        try? FileManager.default.removeItem(at: Store.file)
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                modifiedSince: .distantPast) {}
        data = AppData()
    }
}

// MARK: - Keychain (provider credentials)

enum Keychain {
    private static let service = "com.jobpilot.app"

    static func get(_ account: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func set(_ account: String, _ value: String) {
        delete(account)
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(v.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Text helpers

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    func decodingEntities() -> String {
        var s = self
        for (a, b) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"),
                       ("&nbsp;", " "), ("&ndash;", "–"), ("&mdash;", "—"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s
    }

    /// Reduces an HTML fragment to readable plain text.
    func htmlToText() -> String {
        var s = self
        if s.contains("&lt;") { s = s.decodingEntities() }
        s = s.replacingOccurrences(of: "<(script|style)[\\s\\S]*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6])[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.decodingEntities()
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        return s.trimmed
    }

    func firstMatch(_ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: self) else { return nil }
        return String(self[r])
    }

    func allMatches(_ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        return re.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap {
            guard $0.numberOfRanges > 1, let r = Range($0.range(at: 1), in: self) else { return nil }
            return String(self[r])
        }
    }

    func capped(_ n: Int) -> String { count > n ? String(prefix(n)) + "…" : self }
}

func jobID(for url: String) -> String {
    guard var c = URLComponents(string: url), let host = c.host?.lowercased() else { return url.lowercased() }
    c.fragment = nil
    // LinkedIn links carry tracking parameters that differ on every request.
    if host.contains("linkedin.com") { c.query = nil }
    var path = c.path
    if path.hasSuffix("/") { path.removeLast() }
    return host.replacingOccurrences(of: "www.", with: "") + path + (c.query.map { "?" + $0 } ?? "")
}
