import Foundation
import WebKit

struct FormField: Identifiable, Equatable {
    enum Status { case filled, draft, missing, user }
    var id: String            // "<frame index>|<element id>"
    var label: String
    var type: String          // text, email, tel, textarea, select, radio, checkboxes, checkbox, file, …
    var required: Bool
    var options: [String]
    var value: String
    var status: Status = .missing
    var edited = false

    var isChoice: Bool { type == "select" || type == "radio" }
    var needsAttention: Bool { required && value.trimmed.isEmpty }
}

/// Injected into every frame of the application page. Finds form fields, fills them, and presses submit.
private let formScript = #"""
(function () {
  if (window.__jp) return;
  let n = 0;
  const txt = s => (s || '').replace(/\s+/g, ' ').trim().slice(0, 160);
  const norm = s => (s || '').toLowerCase().replace(/\s+/g, ' ').trim();
  function visible(el) {
    const r = el.getBoundingClientRect(), s = getComputedStyle(el);
    return r.width > 1 && r.height > 1 && s.visibility !== 'hidden' && s.display !== 'none';
  }
  function ownLabel(el) {
    if (el.labels && el.labels.length) { const t = txt(el.labels[0].innerText); if (t) return t; }
    const a = el.getAttribute('aria-label'); if (a) return txt(a);
    const lb = el.getAttribute('aria-labelledby');
    if (lb) {
      const t = txt(lb.split(/\s+/).map(i => { const e = document.getElementById(i); return e ? e.innerText : ''; }).join(' '));
      if (t) return t;
    }
    return '';
  }
  function contextLabel(el) {
    let p = el.parentElement;
    for (let i = 0; i < 4 && p; i++, p = p.parentElement) {
      const l = p.querySelector('legend,label,[class*="label" i],[class*="question" i],h3,h4');
      if (l && !l.contains(el)) { const t = txt(l.innerText); if (t) return t; }
    }
    return '';
  }
  function labelOf(el) {
    return ownLabel(el) || contextLabel(el) || txt(el.placeholder) || txt(el.name) || txt(el.id) || 'Unlabeled field';
  }
  function groupMembers(el) {
    if (!el.name) return [el];
    return [...document.querySelectorAll('input[type="' + el.type + '"][name="' + CSS.escape(el.name) + '"]')];
  }
  function groupLabel(el, members) {
    const fs = el.closest('fieldset,[role=radiogroup],[role=group]');
    if (fs) {
      const lg = fs.querySelector('legend');
      if (lg && txt(lg.innerText)) return txt(lg.innerText);
      const own = ownLabel(fs); if (own) return own;
    }
    let a = el.parentElement;
    while (a && members.some(m => !a.contains(m))) a = a.parentElement;
    const opts = members.map(m => norm(ownLabel(m)));
    for (let i = 0; i < 3 && a; i++, a = a.parentElement) {
      const first = txt((a.innerText || '').split('\n').map(s => s.trim()).filter(s => s)[0]);
      if (first && !opts.includes(norm(first))) return first;
    }
    return txt(el.name) || 'Choice';
  }
  const isRequired = el => el.required || el.getAttribute('aria-required') === 'true';

  function scan() {
    const out = [], groups = {};
    for (const el of document.querySelectorAll('input,textarea,select')) {
      const type = el.tagName === 'SELECT' ? 'select' : (el.tagName === 'TEXTAREA' ? 'textarea' : (el.type || 'text').toLowerCase());
      if (['hidden', 'submit', 'button', 'reset', 'image', 'search', 'password'].includes(type)) continue;
      if (el.disabled) continue;
      const choice = type === 'radio' || type === 'checkbox';
      if (type !== 'file' && !choice && (!visible(el) || el.readOnly)) continue;

      if (choice) {
        const members = groupMembers(el);
        if (type === 'radio' || members.length > 1) {
          const key = type + ':' + (el.name || el.id);
          let g = groups[key];
          if (!g) {
            if (!el.dataset.jpId) el.dataset.jpId = 'f' + (++n);
            g = groups[key] = { id: el.dataset.jpId, label: groupLabel(el, members),
                                type: type === 'radio' ? 'radio' : 'checkboxes',
                                required: members.some(isRequired), options: [], value: '' };
            out.push(g);
          }
          el.dataset.jpGroup = g.id;
          const ol = ownLabel(el) || txt(el.value);
          el.dataset.jpOpt = ol;
          g.options.push(ol);
          if (el.checked) g.value = g.value ? g.value + ' | ' + ol : ol;
          continue;
        }
      }
      if (!el.dataset.jpId) el.dataset.jpId = 'f' + (++n);
      const f = { id: el.dataset.jpId, label: labelOf(el), type: type, required: isRequired(el), options: [], value: '' };
      if (type === 'select') {
        f.options = [...el.options].filter(o => o.value !== '').map(o => txt(o.text)).filter(t => t).slice(0, 120);
        const cur = el.selectedIndex >= 0 ? el.options[el.selectedIndex] : null;
        f.value = cur && cur.value ? txt(cur.text) : '';
      } else if (type === 'checkbox') { f.value = el.checked ? 'Yes' : 'No'; f.options = ['Yes', 'No']; }
      else if (type === 'file') { f.value = el.files && el.files.length ? el.files[0].name : ''; }
      else f.value = el.value || '';
      out.push(f);
    }
    return JSON.stringify(out);
  }

  function setVal(el, v) {
    const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype
                : (el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype);
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, v);   // bypasses React's value tracking
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.dispatchEvent(new Event('blur', { bubbles: true }));
  }
  function pick(opts, v) {
    const t = norm(v), o = opts.map(norm);
    let i = o.indexOf(t);
    if (i < 0) i = o.findIndex(x => x && (x.startsWith(t) || t.startsWith(x)));
    if (i < 0) i = o.findIndex(x => x && x.includes(t));
    return i;
  }
  function fill(values, resume) {
    const done = [];
    for (const id in values) {
      const v = values[id];
      const el = document.querySelector('[data-jp-id="' + id + '"]');
      if (!el) continue;
      const type = el.tagName === 'SELECT' ? 'select' : (el.tagName === 'TEXTAREA' ? 'textarea' : (el.type || 'text').toLowerCase());
      try {
        if (el.dataset.jpGroup) {
          const want = String(v).split('|').map(norm).filter(x => x);
          document.querySelectorAll('[data-jp-group="' + id + '"]').forEach(o => {
            const on = want.includes(norm(o.dataset.jpOpt));
            if (type === 'radio') { if (on && !o.checked) o.click(); }
            else if (on !== o.checked) o.click();
          });
        } else if (type === 'select') {
          const opts = [...el.options], i = pick(opts.map(o => o.text), v);
          if (i < 0) continue;
          setVal(el, opts[i].value);
        } else if (type === 'checkbox') {
          const on = /^(yes|true|1|on)$/i.test(String(v).trim());
          if (on !== el.checked) el.click();
        } else if (type === 'file') {
          if (!resume) continue;
          const b = atob(resume.data), u = new Uint8Array(b.length);
          for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i);
          const dt = new DataTransfer();
          dt.items.add(new File([u], resume.name, { type: 'application/pdf' }));
          el.files = dt.files;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        } else setVal(el, String(v));
        done.push(id);
      } catch (e) {}
    }
    return JSON.stringify(done);
  }
  function submit() {
    const c = [...document.querySelectorAll('button,input[type=submit],[role=button]')].filter(visible).filter(b => !b.disabled);
    const t = b => norm(b.innerText || b.value || b.getAttribute('aria-label'));
    const b = c.find(b => /submit application|send application|submit my application/.test(t(b)))
           || c.find(b => /^(submit|apply|apply now|send)$/.test(t(b)))
           || c.find(b => b.type === 'submit' && /submit|apply|send|finish|complete/.test(t(b)))
           || c.find(b => b.type === 'submit' && b.closest('form') && b.closest('form').querySelector('[data-jp-id]'));
    if (!b) return '';
    const label = t(b) || 'submit';
    b.click();
    return label;
  }
  window.__jp = { scan, fill, submit };
  try { window.webkit.messageHandlers.jp.postMessage('ready'); } catch (e) {}
})();
"""#

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: AutofillSession?
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let frame = message.frameInfo
        Task { @MainActor [weak target] in target?.register(frame) }
    }
}

/// One application attempt: an in-app browser on the listing plus the AI-driven form filler.
@MainActor
final class AutofillSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    enum Phase: Equatable { case loading, idle, scanning, thinking, ready, submitted }

    let job: Job
    let web: WKWebView
    @Published var fields: [FormField] = []
    @Published var phase: Phase = .loading
    @Published var note = ""
    @Published var address = ""
    @Published var pageLoading = false

    private let store: Store
    private let ai: AIService
    private var frames: [WKFrameInfo] = []
    private var shared: [SharedField] = []
    private var attached: Set<String> = []
    private var autoRan = false

    init(job: Job, store: Store, ai: AIService) {
        self.job = job; self.store = store; self.ai = ai
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let handler = WeakHandler()
        cfg.userContentController.add(handler, contentWorld: .defaultClient, name: "jp")
        cfg.userContentController.addUserScript(WKUserScript(source: formScript, injectionTime: .atDocumentEnd,
                                                             forMainFrameOnly: false, in: .defaultClient))
        web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        super.init()
        handler.target = self
        web.navigationDelegate = self
        web.uiDelegate = self
        if let u = URL(string: job.url) { web.load(URLRequest(url: u)) }
        address = job.url
    }

    fileprivate func register(_ frame: WKFrameInfo) { frames.append(frame) }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { pageLoading = true }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        frames.removeAll()
        attached.removeAll()
        address = webView.url?.absoluteString ?? address
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { pageLoading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageLoading = false
        if phase == .loading { phase = .idle; note = "The page could not be loaded: \(error.localizedDescription)" }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoading = false
        address = webView.url?.absoluteString ?? address
        if phase == .loading { phase = .idle }
        guard !autoRan else { return }
        autoRan = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await scanAndFill()
        }
    }
    /// Links that want a new window open in this same view, so nothing pops out of the app.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    // MARK: Page bridge

    private func call(_ body: String, _ args: [String: Any], frame: WKFrameInfo) async -> String {
        (try? await web.callAsyncJavaScript(body, arguments: args, in: frame, contentWorld: .defaultClient) as? String) ?? ""
    }

    private func readFields() async -> [FormField] {
        var all: [FormField] = []
        for (i, frame) in frames.enumerated() {
            let raw = await call("return window.__jp ? window.__jp.scan() : '[]'", [:], frame: frame)
            guard let list = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else { continue }
            for f in list {
                let label = (f["label"] as? String ?? "Field")
                all.append(FormField(id: "\(i)|\(f["id"] as? String ?? "")",
                                     label: label.replacingOccurrences(of: "*", with: "").trimmed,
                                     type: f["type"] as? String ?? "text",
                                     required: (f["required"] as? Bool ?? false) || label.contains("*"),
                                     options: f["options"] as? [String] ?? [],
                                     value: f["value"] as? String ?? ""))
            }
        }
        return all
    }

    // MARK: Scan → AI → fill

    func scanAndFill() async {
        guard phase != .scanning, phase != .thinking else { return }
        phase = .scanning
        note = ""
        var found = await readFields()
        guard found.count >= 2 else {
            fields = []
            phase = .idle
            note = "No application form on this page yet. Go to the form (for example, press the site's Apply button, or sign in), then press Scan & Autofill."
            return
        }
        // Keep anything the user already typed for the same question.
        let previous = Dictionary(fields.filter(\.edited).map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        phase = .thinking
        do {
            let answers = try await askModel(found)
            for i in found.indices {
                let f = found[i]
                if let old = previous[f.label] {
                    found[i].value = old.value; found[i].status = .user; found[i].edited = true
                    continue
                }
                guard let a = answers[f.id] else { continue }
                if f.type == "file" {
                    let hasResume = store.data.resumeFile != nil
                    if a.value == "__RESUME__", hasResume { found[i].value = "__RESUME__"; found[i].status = .filled }
                    continue
                }
                if !a.value.isEmpty {
                    found[i].value = a.value
                    found[i].status = a.status == "draft" ? .draft : .filled
                }
            }
        } catch {
            note = "The AI could not fill this form: \(error.localizedDescription) You can still fill the fields yourself."
        }
        fields = found
        await pushToPage()
        phase = .ready
    }

    private func askModel(_ list: [FormField]) async throws -> [String: (value: String, status: String)] {
        let spec = list.map { f -> [String: Any] in
            var d: [String: Any] = ["id": f.id, "label": f.label, "type": f.type, "required": f.required]
            if !f.options.isEmpty { d["options"] = f.options }
            if !f.value.isEmpty && f.type != "file" { d["current_value"] = f.value }
            return d
        }
        let specJSON = String(decoding: try JSONSerialization.data(withJSONObject: spec, options: [.prettyPrinted]), as: UTF8.self)
        let obj = try await ai.json(.autofill, system: """
            You fill in job application forms for a candidate, using only facts found in their saved information and \
            résumé. You never invent facts: no made-up dates, addresses, salaries, IDs, work-authorisation or visa \
            answers, demographic answers, or references. When the information does not answer a field, you leave it \
            for the candidate.
            """, prompt: """
            Fill each form field below.
            - status "filled": the answer comes directly from the candidate's information. Format it for the field \
            (e.g. split a full name into first/last, a phone number as written).
            - status "draft": open-ended questions (cover letter, "why this role", "tell us about…"). Write a concise, \
            specific, truthful answer in the candidate's voice from the résumé and the job. The candidate will review it.
            - status "missing": the information is not available. Set value to null. Do this rather than guess, \
            including for consent checkboxes and legal or demographic questions.
            - select / radio: value must be exactly one of the options. checkboxes: matching options joined with " | ". \
            Single checkbox: "Yes" or "No".
            - file: use "__RESUME__" for a résumé/CV upload; anything else is "missing".
            - Keep a field's current_value if it is already correct.
            Return {"fields":[{"id":"","value":"","status":"filled"}]} with one entry per field.

            JOB: \(job.title) at \(job.company) (\(job.location))
            \(String(job.description.prefix(5000)))

            CANDIDATE INFORMATION:
            \(store.candidateSummary.isEmpty ? "(none saved)" : store.candidateSummary)

            RÉSUMÉ:
            \(store.data.resumeText.isEmpty ? "(none provided)" : store.data.resumeText)

            FORM FIELDS:
            \(specJSON)
            """)
        var out: [String: (String, String)] = [:]
        for a in obj["fields"] as? [[String: Any]] ?? [] {
            guard let id = a["id"] as? String else { continue }
            var value = ""
            if let s = a["value"] as? String { value = s }
            else if let b = a["value"] as? Bool { value = b ? "Yes" : "No" }
            else if let n = a["value"] as? NSNumber { value = n.stringValue }
            else if let arr = a["value"] as? [String] { value = arr.joined(separator: " | ") }
            let status = a["status"] as? String ?? "filled"
            out[id] = (status == "missing" ? "" : value.trimmed, status)
        }
        return out
    }

    /// Writes the current field values into the page and remembers anything the user supplied.
    func pushToPage() async {
        var resume: [String: String]?
        if let name = store.data.resumeFile, let data = try? Data(contentsOf: Store.resumeURL) {
            resume = ["name": name, "data": data.base64EncodedString()]
        }
        for (i, frame) in frames.enumerated() {
            var values: [String: String] = [:]
            for f in fields where f.id.hasPrefix("\(i)|") && !f.value.trimmed.isEmpty {
                if f.type == "file" && (f.value != "__RESUME__" || attached.contains(f.id)) { continue }
                values[String(f.id.dropFirst("\(i)|".count))] = f.value
            }
            guard !values.isEmpty else { continue }
            let raw = await call("return window.__jp ? window.__jp.fill(values, resume) : '[]'",
                                 ["values": values, "resume": resume as Any? ?? NSNull()], frame: frame)
            let done = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String]) ?? []
            for id in done { if fields.first(where: { $0.id == "\(i)|\(id)" })?.type == "file" { attached.insert("\(i)|\(id)") } }
        }
        for f in fields where !f.value.trimmed.isEmpty {
            let shown = f.type == "file" ? "Résumé (\(store.data.resumeFile ?? "PDF")) attached" : f.value
            if let i = shared.firstIndex(where: { $0.label == f.label }) { shared[i].value = shown }
            else { shared.append(SharedField(label: f.label, value: shown)) }
            // Answers the user typed are saved so the next application can use them.
            if f.edited, f.type != "file", f.type != "checkbox", !(f.type == "textarea" && f.value.count > 300) {
                store.upsertInfo(key: f.label.capped(80), value: f.value)
            }
        }
    }

    func edit(_ id: String, _ value: String) {
        guard let i = fields.firstIndex(where: { $0.id == id }), fields[i].value != value else { return }
        fields[i].value = value
        fields[i].edited = true
        fields[i].status = .user
    }

    var missingRequired: [FormField] { fields.filter(\.needsAttention) }
    var drafts: [FormField] { fields.filter { $0.status == .draft } }

    /// Applies the latest values, then presses the page's submit button. Returns false if no button was found.
    func submit() async -> Bool {
        await pushToPage()
        try? await Task.sleep(nanoseconds: 400_000_000)
        for frame in frames.reversed() {
            let label = await call("return window.__jp ? window.__jp.submit() : ''", [:], frame: frame)
            if !label.isEmpty {
                phase = .submitted
                note = "Pressed “\(label)”. Check the page for a confirmation. If the form continues on another page, press Scan & Autofill again."
                return true
            }
        }
        note = "No submit button was found. Press the site's own submit button in the page, then choose Record as submitted."
        return false
    }

    func record() {
        store.recordSubmission(job, shared: shared, method: "Autofill")
    }

    func close() {
        web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.navigationDelegate = nil
        web.uiDelegate = nil
    }
}
