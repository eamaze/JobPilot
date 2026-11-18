import Foundation
import WebKit

// MARK: - Sources

struct JobSource: Identifiable {
    let id: String, title: String, note: String
    var signInURL: String? = nil

    static let all = [
        JobSource(id: "linkedin", title: "LinkedIn", note: "Public job search. Applying usually needs you to sign in.",
                  signInURL: "https://www.linkedin.com/login"),
        JobSource(id: "handshake", title: "Handshake", note: "Uses your Handshake session. Sign in once first.",
                  signInURL: "https://app.joinhandshake.com/login"),
        JobSource(id: "remotive", title: "Remotive", note: "Remote roles."),
        JobSource(id: "arbeitnow", title: "Arbeitnow", note: "Tech and European roles."),
        JobSource(id: "web", title: "Web search", note: "Searches the open web and reads the pages it finds."),
        JobSource(id: "custom", title: "My career pages", note: "Reads the pages you list below on every pass."),
    ]
}

private let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

private func fetch(_ url: String) async throws -> String {
    guard let u = URL(string: url) else { throw AIError(message: "Bad URL") }
    var req = URLRequest(url: u)
    req.timeoutInterval = 25
    req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw AIError(message: "HTTP \(status)") }
    return String(decoding: data, as: UTF8.self)
}

private func enc(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
}

private func makeJob(title: String, company: String, location: String, url: String, source: String, description: String) -> Job? {
    let t = title.htmlToText(), u = url.trimmed
    guard !t.isEmpty, u.hasPrefix("http") else { return nil }
    return Job(id: jobID(for: u), title: t, company: company.htmlToText(), location: location.htmlToText(),
               url: u, source: source, description: description)
}

enum Boards {
    static func linkedin(query: String, location: String) async throws -> [Job] {
        var url = "https://www.linkedin.com/jobs-guest/jobs/api/seeMoreJobPostings/search?keywords=\(enc(query))&start=0"
        if !location.isEmpty { url += "&location=\(enc(location))" }
        let html = try await fetch(url)
        return html.components(separatedBy: "<li>").dropFirst().compactMap { chunk in
            guard let href = chunk.firstMatch("base-card__full-link[^>]*?href=\"([^\"]+)\""),
                  let title = chunk.firstMatch("base-search-card__title[^>]*>(.*?)</h3>") else { return nil }
            let company = chunk.firstMatch("base-search-card__subtitle[^>]*>(.*?)</h4>") ?? ""
            let loc = chunk.firstMatch("job-search-card__location[^>]*>(.*?)</span>") ?? ""
            let clean = href.decodingEntities().components(separatedBy: "?")[0]
            return makeJob(title: title, company: company, location: loc, url: clean, source: "LinkedIn", description: "")
        }
    }

    /// LinkedIn search cards carry no description, so fetch it before judging the fit.
    static func linkedinDescription(_ job: Job) async -> String {
        guard let id = job.url.firstMatch("-(\\d{6,})/?$") ?? job.url.firstMatch("/view/(\\d{6,})"),
              let html = try? await fetch("https://www.linkedin.com/jobs-guest/jobs/api/jobPosting/\(id)") else { return "" }
        return (html.firstMatch("show-more-less-html__markup[^>]*>(.*?)</div>") ?? "").htmlToText()
    }

    static func remotive(query: String) async throws -> [Job] {
        let raw = try await fetch("https://remotive.com/api/remote-jobs?search=\(enc(query))&limit=20")
        let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        return (obj["jobs"] as? [[String: Any]] ?? []).compactMap { j in
            makeJob(title: j["title"] as? String ?? "", company: j["company_name"] as? String ?? "",
                    location: "Remote · " + (j["candidate_required_location"] as? String ?? ""),
                    url: j["url"] as? String ?? "", source: "Remotive",
                    description: (j["description"] as? String ?? "").htmlToText())
        }
    }

    static func arbeitnow(queries: [String]) async throws -> [Job] {
        let raw = try await fetch("https://www.arbeitnow.com/api/job-board-api")
        let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        // The feed has no keyword search, so keep postings whose title contains every word of some query.
        let wanted = queries.map { $0.lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 } }.filter { !$0.isEmpty }
        return (obj["data"] as? [[String: Any]] ?? []).compactMap { j in
            let title = j["title"] as? String ?? ""
            let lower = title.lowercased()
            guard wanted.contains(where: { $0.allSatisfy(lower.contains) }) else { return nil }
            let remote = (j["remote"] as? Bool ?? false) ? " · Remote" : ""
            return makeJob(title: title, company: j["company_name"] as? String ?? "",
                           location: (j["location"] as? String ?? "") + remote,
                           url: j["url"] as? String ?? "", source: "Arbeitnow",
                           description: (j["description"] as? String ?? "").htmlToText())
        }
    }

    /// Result links from a DuckDuckGo web search (ads skipped).
    static func webSearch(_ query: String) async throws -> [String] {
        let html = try await fetch("https://html.duckduckgo.com/html/?q=\(enc(query))")
        var out: [String] = []
        for href in html.allMatches("class=\"result__a\"[^>]*?href=\"([^\"]+)\"") {
            var link = href.decodingEntities()
            if link.contains("duckduckgo.com/y.js") { continue }
            if link.contains("uddg="), let target = URLComponents(string: link.hasPrefix("//") ? "https:" + link : link)?
                .queryItems?.first(where: { $0.name == "uddg" })?.value { link = target }
            if link.hasPrefix("http"), !out.contains(link) { out.append(link) }
        }
        return out
    }
}

// MARK: - Page loader (renders a page in a hidden web view, with the user's signed-in sessions)

struct LoadedPage {
    var url: String
    var text: String
    var links: [[String: String]]
}

@MainActor
final class PageLoader: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private var pending: CheckedContinuation<Void, Never>?

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 1800), configuration: cfg)
        web.customUserAgent = browserUA
        super.init()
        web.navigationDelegate = self
    }

    func load(_ url: String) async -> LoadedPage? {
        guard let u = URL(string: url) else { return nil }
        web.load(URLRequest(url: u, timeoutInterval: 25))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            pending = c
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self?.finish()
            }
        }
        try? await Task.sleep(nanoseconds: 2_500_000_000)   // let client-rendered pages draw
        let js = """
            return JSON.stringify({url: location.href, text: (document.body ? document.body.innerText : '').slice(0, 14000),
              links: [...document.querySelectorAll('a[href]')].map(a => ({t: (a.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 90), h: a.href}))
                .filter(l => l.t.length > 3 && l.h.startsWith('http')).slice(0, 220)});
            """
        guard let raw = try? await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .defaultClient) as? String,
              let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
        let links = (obj["links"] as? [[String: String]] ?? [])
        return LoadedPage(url: obj["url"] as? String ?? url, text: obj["text"] as? String ?? "", links: links)
    }

    private func finish() { pending?.resume(); pending = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
}

// MARK: - Engine

struct LogLine: Identifiable {
    enum Kind { case info, match, skip, error }
    let id = UUID()
    let time = Date()
    let kind: Kind
    let text: String
}

@MainActor
final class SearchEngine: ObservableObject {
    @Published var enabled = false
    @Published var working = false
    @Published var status = "Search is off"
    @Published var log: [LogLine] = []
    @Published var checked = 0
    @Published var matched = 0

    private let store: Store
    private let ai: AIService
    private var task: Task<Void, Never>?
    private lazy var loader = PageLoader()
    private let perPassLimit = 60

    init(store: Store, ai: AIService) { self.store = store; self.ai = ai }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        task?.cancel()
        task = nil
        if on {
            task = Task { await loop() }
        } else {
            working = false
            status = "Search is off"
        }
    }

    private func say(_ kind: LogLine.Kind, _ text: String) {
        log.insert(LogLine(kind: kind, text: text), at: 0)
        if log.count > 300 { log.removeLast(log.count - 300) }
    }

    private func loop() async {
        while !Task.isCancelled {
            working = true
            let ok = await pass()
            working = false
            if Task.isCancelled { return }
            if !ok { enabled = false; status = "Search is off"; return }
            let mins = store.data.search.intervalMinutes
            let next = Date().addingTimeInterval(Double(mins) * 60)
            status = "Idle · next pass at \(next.formatted(date: .omitted, time: .shortened))"
            try? await Task.sleep(nanoseconds: UInt64(mins) * 60_000_000_000)
        }
    }

    /// One full search pass. Returns false when it cannot run at all (missing setup).
    private func pass() async -> Bool {
        let prefs = store.data.preferences.trimmed
        guard !prefs.isEmpty else { say(.error, "Describe the jobs you want before searching."); return false }
        guard ai.isReady(.matching) else { say(.error, "Set up an AI model for job matching (AI menu, top right)."); return false }

        status = "Planning search…"
        var queries: [String] = []
        var location = store.data.search.location.trimmed
        do {
            let plan = try await ai.json(.matching, system: "You turn a job seeker's wishes into job-board search queries.", prompt: """
                Write up to 4 short search queries (2–4 words each: job titles or key skills, no locations, no filler) \
                that would surface the jobs described below on a job board. Also give the location if one is stated \
                (city/region/country, or "" if none or remote-only).
                Return {"queries":["..."],"location":""}

                WHAT THE CANDIDATE WANTS:
                \(prefs)
                """)
            queries = (plan["queries"] as? [String] ?? []).map(\.trimmed).filter { !$0.isEmpty }
            if location.isEmpty { location = (plan["location"] as? String ?? "").trimmed }
        } catch {
            say(.error, "Could not plan the search: \(error.localizedDescription)")
            return false
        }
        guard !queries.isEmpty else { say(.error, "The model produced no search queries."); return false }
        queries = Array(queries.prefix(4))
        say(.info, "Searching for: " + queries.joined(separator: " · ") + (location.isEmpty ? "" : " in \(location)"))

        // Gather
        var found: [Job] = []
        func add(_ jobs: [Job], _ source: String) {
            var fresh = 0
            for j in jobs where !store.isKnown(j) && !found.contains(where: { $0.id == j.id || $0.signature == j.signature }) {
                found.append(j); fresh += 1
            }
            say(.info, "\(source): \(jobs.count) listings, \(fresh) new")
        }
        let on = store.data.search.sources
        func gather(_ id: String, _ name: String, _ work: () async throws -> [Job]) async {
            guard on[id] ?? false, !Task.isCancelled else { return }
            status = "Searching \(name)…"
            do { add(try await work(), name) } catch { say(.error, "\(name): \(error.localizedDescription)") }
        }

        await gather("linkedin", "LinkedIn") {
            var all: [Job] = []
            for q in queries {
                all += try await Boards.linkedin(query: q, location: location)
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            return all
        }
        await gather("remotive", "Remotive") {
            var all: [Job] = []
            for q in queries { all += try await Boards.remotive(query: q) }
            return all
        }
        await gather("arbeitnow", "Arbeitnow") { try await Boards.arbeitnow(queries: queries) }
        await gather("handshake", "Handshake") {
            var all: [Job] = []
            for q in queries.prefix(2) {
                let page = "https://app.joinhandshake.com/stu/postings?page=1&per_page=25&query=\(enc(q))"
                let jobs = try await self.readPage(page, source: "Handshake")
                all += jobs
            }
            return all
        }
        await gather("web", "Web search") {
            var all: [Job] = []
            for q in queries.prefix(2) {
                let links = try await Boards.webSearch(q + " jobs " + location + " apply")
                for link in links.prefix(4) where !Task.isCancelled {
                    self.status = "Reading \(URL(string: link)?.host ?? "page")…"
                    all += (try? await self.readPage(link, source: "Web")) ?? []
                }
            }
            return all
        }
        await gather("custom", "My career pages") {
            var all: [Job] = []
            for link in self.store.data.search.customURLs.map(\.trimmed) where link.hasPrefix("http") {
                all += try await self.readPage(link, source: URL(string: link)?.host ?? "Career page")
            }
            return all
        }

        // Judge
        let batch = Array(found.prefix(perPassLimit))
        if found.count > batch.count { say(.info, "Reviewing the first \(batch.count) of \(found.count); the rest wait for the next pass.") }
        for (i, var job) in batch.enumerated() {
            if Task.isCancelled { return true }
            status = "Reviewing \(i + 1) of \(batch.count): \(job.title.capped(40))"
            if job.source == "LinkedIn", job.description.isEmpty { job.description = await Boards.linkedinDescription(job) }
            do {
                let verdict = try await judge(job, prefs: prefs)
                checked += 1
                job.score = verdict.score
                job.reason = verdict.reason
                if verdict.fit && verdict.score >= store.data.search.minScore {
                    matched += 1
                    store.data.results.insert(job, at: 0)
                    say(.match, "Match (\(job.score)): \(job.title) · \(job.company)")
                } else {
                    store.markSeen(job, "rejected")
                    say(.skip, "Skipped (\(job.score)): \(job.title) · \(job.company)")
                }
            } catch {
                say(.error, "Could not review “\(job.title.capped(40))”: \(error.localizedDescription)")
                if error.localizedDescription.contains("API key") || error.localizedDescription.contains("reach") { break }
            }
        }
        say(.info, "Pass finished.")
        return true
    }

    /// Loads a page and has the model pull job postings out of it. Works for listing pages and single postings.
    private func readPage(_ url: String, source: String) async throws -> [Job] {
        guard let page = await loader.load(url) else { throw AIError(message: "Could not load \(url)") }
        if page.url.lowercased().contains("login") || page.url.lowercased().contains("signin") {
            throw AIError(message: "Needs sign-in. Use the Sign in button next to this source.")
        }
        guard page.text.count > 200 else { return [] }
        let links = page.links.map { "\($0["t"] ?? "") → \($0["h"] ?? "")" }.joined(separator: "\n")
        let obj = try await ai.json(.matching, system: """
            You extract job postings from the text of a web page. Report only postings actually present on the page.
            """, prompt: """
            If this page is a single job posting, return that one job with url set to the page URL. If it lists several \
            postings, return each one with the url copied exactly from the LINKS list. If it has no job postings, return \
            an empty list. "description" should carry every detail the page gives about the role (duties, requirements, pay).
            Return {"jobs":[{"title":"","company":"","location":"","url":"","description":""}]}

            PAGE URL: \(page.url)

            PAGE TEXT:
            \(page.text)

            LINKS:
            \(links)
            """)
        return (obj["jobs"] as? [[String: Any]] ?? []).prefix(25).compactMap { j in
            makeJob(title: j["title"] as? String ?? "", company: j["company"] as? String ?? "",
                    location: j["location"] as? String ?? "", url: j["url"] as? String ?? "",
                    source: source, description: j["description"] as? String ?? "")
        }
    }

    private func judge(_ job: Job, prefs: String) async throws -> (fit: Bool, score: Int, reason: String) {
        let obj = try await ai.json(.matching, system: """
            You screen job listings for one candidate. Be discerning: a listing is a fit only if it matches what the \
            candidate asked for and they are plausibly qualified. Judge on the evidence given.
            """, prompt: """
            Decide whether this listing is a good fit. Score 0–100 (70+ means worth applying). Give one plain sentence \
            explaining the verdict, addressed to the candidate.
            Return {"fit":true,"score":0,"reason":""}

            WHAT THE CANDIDATE WANTS:
            \(prefs)

            CANDIDATE:
            \(store.candidateSummary)

            RÉSUMÉ:
            \(store.data.resumeText.isEmpty ? "(none provided)" : store.data.resumeText)

            LISTING:
            Title: \(job.title)
            Company: \(job.company)
            Location: \(job.location)
            Description:
            \(job.description.isEmpty ? "(no description available)" : String(job.description.prefix(9000)))
            """)
        let score = (obj["score"] as? Int) ?? Int((obj["score"] as? Double) ?? 0)
        return ((obj["fit"] as? Bool) ?? (score >= 70), score, (obj["reason"] as? String ?? "").trimmed)
    }
}
