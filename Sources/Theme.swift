import SwiftUI
import WebKit

extension Color {
    static let crimson = Color(red: 0.863, green: 0.078, blue: 0.235)
    static let bg = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
    static let subtle = Color.primary.opacity(0.06)
}

extension Animation {
    static let smooth = Animation.spring(response: 0.38, dampingFraction: 0.86)
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.crimson.opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SoftButton: ButtonStyle {
    var tint: Color = .primary
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint.opacity(enabled ? 1 : 0.4))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.line, lineWidth: 0.5))
    }
}

struct IconButton: View {
    let symbol: String
    var help = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 26)
                .background(Color.primary.opacity(hover ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct Card: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.line, lineWidth: 0.5))
    }
}

struct InputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.subtle, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.line, lineWidth: 0.5))
    }
}

extension View {
    func card(_ padding: CGFloat = 18) -> some View { modifier(Card(padding: padding)) }
    func input() -> some View { modifier(InputStyle()) }
}

/// Segmented choice with a sliding crimson highlight.
struct Seg<T: Hashable>: View {
    let options: [(String, T)]
    @Binding var selection: T
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let on = opt.1 == selection
                Button {
                    withAnimation(.smooth) { selection = opt.1 }
                } label: {
                    Text(opt.0)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.crimson)
                                    .matchedGeometryEffect(id: "sel", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary
    var solid = false
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(solid ? Color.white : color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(solid ? 1 : 0.14), in: Capsule())
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 24, weight: .bold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

struct EmptyState: View {
    let symbol: String, title: String, message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Color.crimson.opacity(0.8))
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

struct Label2: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
    }
}

/// Dimmed in-app modal layer. Every pop-up in the app is drawn with this, inside the window.
struct Popup<Content: View>: View {
    var dismiss: (() -> Void)?
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            Color.black.opacity(0.38).ignoresSafeArea().onTapGesture { dismiss?() }
            content
                .background(Color.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.line, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
        .transition(.opacity)
    }
}

struct WebContainer: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
