import Foundation
import PDFKit

struct AIError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Routes every AI request to the provider chosen for that feature.
/// To add a provider: add a case to `ProviderID`, its settings to `AISettings`, and a branch in `complete`.
@MainActor
final class AIService {
    unowned let store: Store
    init(store: Store) { self.store = store }

    func isReady(_ feature: AIFeature) -> Bool { isReady(store.data.ai.provider(for: feature)) }

    func isReady(_ provider: ProviderID) -> Bool {
        switch provider {
        case .claude: return !Keychain.get("claude").isEmpty
        case .ollama: return !store.data.ai.ollama.model.isEmpty
        }
    }

    func complete(_ feature: AIFeature, system: String, prompt: String) async throws -> String {
        let ai = store.data.ai
        switch ai.provider(for: feature) {
        case .claude:
            let key = Keychain.get("claude")
            guard !key.isEmpty else { throw AIError(message: "Add your Claude API key in the AI menu first.") }
            return try await AIService.claude(key: key, settings: ai.claude, system: system, prompt: prompt)
        case .ollama:
            guard !ai.ollama.model.isEmpty else { throw AIError(message: "Choose an Ollama model in the AI menu first.") }
            return try await AIService.ollama(key: Keychain.get("ollama"), settings: ai.ollama, system: system, prompt: prompt)
        }
    }

    /// Asks for a JSON object and parses it, tolerating prose or code fences around it.
    func json(_ feature: AIFeature, system: String, prompt: String) async throws -> [String: Any] {
        let text = try await complete(feature, system: system + "\nReply with a single JSON object and nothing else.", prompt: prompt)
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any] else {
            throw AIError(message: "The model did not return valid JSON.")
        }
        return obj
    }

    // MARK: Claude (Messages API over HTTPS)

    nonisolated private static let fallbackModels: Set<String> = ["claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5"]

    nonisolated static func claude(key: String, settings: ClaudeSettings, system: String, prompt: String,
                                   allowFallback: Bool = true) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": settings.model,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
            "output_config": ["effort": settings.effort],
        ]
        // If a safety classifier declines a request, let the API re-run it on a fallback model.
        let useFallback = allowFallback && fallbackModels.contains(settings.model)
        if useFallback {
            body["fallbacks"] = "default"
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            if status == 400, useFallback, msg.lowercased().contains("fallback") {
                return try await claude(key: key, settings: settings, system: system, prompt: prompt, allowFallback: false)
            }
            switch status {
            case 401: throw AIError(message: "Claude rejected the API key.")
            case 403: throw AIError(message: "This API key cannot use \(ClaudeModel.name(settings.model)): \(msg)")
            case 404: throw AIError(message: "Model not available: \(settings.model)")
            case 429: throw AIError(message: "Claude rate limit reached. Try again shortly.")
            case 500...: throw AIError(message: "Claude is temporarily unavailable (\(status)).")
            default: throw AIError(message: "Claude error: \(msg)")
            }
        }
        if obj["stop_reason"] as? String == "refusal" { throw AIError(message: "Claude declined this request.") }
        let text = (obj["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError(message: "Claude returned an empty reply.") }
        return text
    }

    nonisolated static func testClaude(key: String) async throws {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        req.timeoutInterval = 20
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        let (_, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw AIError(message: "That API key was not accepted.") }
        guard status == 200 else { throw AIError(message: "Could not reach Claude (HTTP \(status)).") }
    }

    // MARK: Ollama

    nonisolated private static func ollamaRequest(_ base: String, _ path: String, key: String) throws -> URLRequest {
        var b = base.trimmed
        while b.hasSuffix("/") { b.removeLast() }
        guard let url = URL(string: b + path) else { throw AIError(message: "The Ollama address is not a valid URL.") }
        var req = URLRequest(url: url)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return req
    }

    nonisolated static func ollama(key: String, settings: OllamaSettings, system: String, prompt: String) async throws -> String {
        var req = try ollamaRequest(settings.baseURL, "/api/chat", key: key)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": settings.model, "stream": false, "format": "json",
            "options": ["temperature": settings.temperature],
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
        ] as [String: Any])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw AIError(message: "Ollama error: \(obj["error"] as? String ?? "request failed")")
            }
            return ((obj["message"] as? [String: Any])?["content"] as? String) ?? ""
        } catch let e as AIError { throw e } catch {
            throw AIError(message: "Could not reach Ollama at \(settings.baseURL). Is it running?")
        }
    }

    nonisolated static func ollamaModels(base: String, key: String) async throws -> [String] {
        var req = try ollamaRequest(base, "/api/tags", key: key)
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIError(message: "Ollama answered, but not with a model list.")
            }
            return (obj["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.sorted()
        } catch let e as AIError { throw e } catch {
            throw AIError(message: "Could not reach Ollama at \(base). Is it running?")
        }
    }
}

// MARK: - Résumé import

@MainActor
enum ResumeImporter {
    /// Copies the PDF into the app's storage and extracts its text. Returns false if it is not a readable PDF.
    static func attach(_ url: URL, store: Store) -> Bool {
        guard let doc = PDFDocument(url: url) else { return false }
        try? FileManager.default.removeItem(at: Store.resumeURL)
        do { try FileManager.default.copyItem(at: url, to: Store.resumeURL) } catch { return false }
        store.data.resumeFile = url.lastPathComponent
        store.data.resumeText = (doc.string ?? "").trimmed
        return true
    }

    static func remove(store: Store) {
        try? FileManager.default.removeItem(at: Store.resumeURL)
        store.data.resumeFile = nil
        store.data.resumeText = ""
    }

    /// Fills candidate info from the résumé text. Uses the AI model when one is set up, otherwise
    /// falls back to pattern-matching the email address and phone number.
    static func extract(store: Store, ai: AIService, overwrite: Bool) async -> String? {
        let text = store.data.resumeText
        guard !text.isEmpty else { return "No text could be read from that PDF (it may be a scanned image)." }
        var failure: String?
        if ai.isReady(.resume) {
            do {
                let obj = try await ai.json(.resume, system: """
                    You extract a job candidate's details from résumé text. Report only what the résumé states; never guess.
                    """, prompt: """
                    Extract these fields when present: Full Name, Email, Phone, Location, LinkedIn, Website, GitHub, \
                    Current Title, Years of Experience, Highest Education, School, Graduation Year, Skills, Work Experience \
                    (a compact summary: role, employer, dates per line). Add other fields a job application commonly asks for \
                    if the résumé states them. Omit anything not present.
                    Return {"fields":[{"key":"Full Name","value":"..."}]}

                    RÉSUMÉ:
                    \(text)
                    """)
                for f in obj["fields"] as? [[String: Any]] ?? [] {
                    if let k = f["key"] as? String, let v = f["value"] as? String {
                        store.upsertInfo(key: k, value: v, overwrite: overwrite)
                    }
                }
                return nil
            } catch { failure = error.localizedDescription }
        }
        if let m = text.firstMatch("([A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,})") { store.upsertInfo(key: "Email", value: m, overwrite: overwrite) }
        if let m = text.firstMatch("(\\+?\\d[\\d\\s().-]{8,16}\\d)") { store.upsertInfo(key: "Phone", value: m, overwrite: overwrite) }
        return failure
    }
}
