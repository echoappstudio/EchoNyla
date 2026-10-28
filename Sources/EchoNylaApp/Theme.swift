import AppKit
import EchoNylaCore
import SwiftUI

/// The colours of the skin in use (Signature by default; see `SkinStore`). Reading them while a
/// view draws makes the view redraw when the skin changes. The names keep their old "brass" wording:
/// `brass` is the skin's accent.
enum NylaStyle {
    private static var palette: SkinPalette { SkinStore.shared.palette }

    static var isDark: Bool { SkinStore.shared.isDark }
    /// Signature draws silver titles and lit card edges in dark mode, like Verbyn.
    static var isSignature: Bool { SkinStore.shared.skin == .signature }
    /// Cards and rows.
    static var surface: Color { Color(palette.surface) }
    static var accentGradient: [Color] { [brassLight, brass, brassDeep] }
    /// The website's silver headline gradient, used for page titles in dark Signature.
    static let silver = LinearGradient(
        colors: [Color(white: 1), Color(red: 0.851, green: 0.855, blue: 0.863), Color(red: 0.553, green: 0.561, blue: 0.576)],
        startPoint: .top, endPoint: .bottom)
    static var brass: Color { Color(palette.accent) }
    /// The accent a little lighter and a little deeper, for gradients (the Apple Intelligence mark).
    static var brassLight: Color { Color(palette.accent.mixed(with: RGB(hex: 0xFFFFFF), amount: 0.3)) }
    static var brassDeep: Color { Color(palette.accent.mixed(with: RGB(hex: 0x000000), amount: 0.3)) }
    /// Text on the accent-coloured main button.
    static var onAccent: Color { Color(palette.onAccent) }
    static var sidebarFill: Color { Color(palette.sidebar) }
    static var hairline: Color { wash(isDark ? 0.09 : 0.12) }
    static var windowBackgroundNS: NSColor { NSColor(palette.window) }

    /// A veil that darkens a light skin and lightens a dark one: white over dark skins, black over light ones.
    static func wash(_ opacity: Double) -> Color {
        isDark ? Color.white.opacity(opacity) : Color.black.opacity(opacity)
    }

    /// A raised surface: a faint white veil on dark skins, a strong one on light skins (where a card is nearly white).
    static func raised(_ opacity: Double) -> Color {
        Color.white.opacity(isDark ? opacity : min(1, opacity * 6))
    }
}

/// The skin's window colour, faintly tinted with the skin.
struct WindowBackground: View {
    var body: some View {
        Color(SkinStore.shared.palette.window)
    }
}

/// The surface of every card: the skin's card colour with a hairline edge, its top lit in dark
/// Signature (as on the website and in Verbyn).
struct CardSurface: ViewModifier {
    var radius: CGFloat
    var hovering: Bool

    func body(content: Content) -> some View {
        let dark = NylaStyle.isDark
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(shape.fill(NylaStyle.surface))
            .overlay {
                shape.fill(hovering ? NylaStyle.wash(dark ? 0.04 : 0.025) : Color.clear).allowsHitTesting(false)
            }
            .overlay { shape.strokeBorder(NylaStyle.wash(dark ? 0.08 : 0.09), lineWidth: 1) }
            .overlay(alignment: .top) {
                if dark && NylaStyle.isSignature {
                    LinearGradient(colors: [.clear, .white.opacity(0.24), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(height: 1)
                        .padding(.horizontal, radius)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: Color.black.opacity(dark ? 0.3 : 0.05), radius: dark ? 8 : 6, y: 2)
    }
}

extension View {
    func cardSurface(radius: CGFloat = 14, hovering: Bool = false) -> some View {
        modifier(CardSurface(radius: radius, hovering: hovering))
    }
}

extension View {
    /// The skin's tint, card-style group boxes and light or dark appearance for everything inside.
    func nylaChrome() -> some View {
        modifier(NylaChrome())
    }
}

struct NylaChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(NylaStyle.brass)
            .groupBoxStyle(CardGroupBoxStyle())
            .preferredColorScheme(NylaStyle.isDark ? .dark : .light)
    }
}

/// Every `GroupBox` in the app: a soft card with a thin edge and a small brass heading.
struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.1)
                .foregroundStyle(NylaStyle.brass)
            configuration.content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// A card without a heading.
struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }
}

/// Small rounded buttons (Undo, Rename, Show in Finder).
struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(NylaStyle.wash(configuration.isPressed ? 0.17 : 0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(NylaStyle.hairline, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// The main action: a pill in the skin's accent with the skin's own text colour on it (white text is
/// hard to read on the pale accents of the dark skins).
struct BrassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(NylaStyle.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(NylaStyle.brass, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
}

extension ButtonStyle where Self == BrassButtonStyle {
    static var brass: BrassButtonStyle { BrassButtonStyle() }
}

/// A small tag, like the folder a file went to.
struct Chip: View {
    let text: String
    var highlighted = false
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .medium))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(highlighted ? NylaStyle.brass : Color.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .background(highlighted ? NylaStyle.brass.opacity(0.14) : NylaStyle.wash(0.08), in: Capsule())
    }
}

/// A small uppercase brass heading for a block of the panel.
struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(1.1)
            .foregroundStyle(NylaStyle.brass)
    }
}

struct PageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    let accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                PageTitle(title)
                Text(subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory
                .padding(.top, 6)
        }
    }
}

/// A screen's big title ("Activity", "Settings"). In dark Signature it takes the website's silver
/// gradient; otherwise it is the normal text colour.
struct PageTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        let title = Text(text)
            .font(.system(size: 30, weight: .semibold))
            .tracking(-0.3)
        if NylaStyle.isSignature && NylaStyle.isDark {
            title.foregroundStyle(NylaStyle.silver)
        } else {
            title
        }
    }
}

/// A scrolling page: large title, subtitle (with optional buttons on the right), content, privacy footer.
struct Page<Accessory: View, Content: View>: View {
    let title: String
    let subtitle: String
    let accessory: Accessory
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: title, subtitle: subtitle, accessory: accessory)
                content
                PrivacyFooter()
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(WindowBackground().ignoresSafeArea())
    }
}

extension Page where Accessory == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// "TODAY", "YESTERDAY": the small heading above a day's entries.
struct DayLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(1.3)
            .foregroundStyle(.secondary)
    }
}

/// A small action with an icon above its caption (Undo, Rename, Finder).
struct IconAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(hovering ? NylaStyle.brass : Color.secondary)
            .frame(minWidth: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(title)
    }
}

struct PrivacyFooter: View {
    var body: some View {
        Label("Your files are read and sorted on this Mac only. Nothing is uploaded, and nothing is ever deleted.", systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

struct Caption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ErrorLabel: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shows Apple Intelligence's state in one line.
struct IntelligenceStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let reason = model.aiUnavailableReason {
            Label(reason, systemImage: "sparkles.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label("\(model.modelName) is on, running on this Mac only.", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(NylaStyle.brass)
        }
    }
}

enum TimeText {
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// One entry in Activity: what happened, where it went, why, and Undo / Rename / Move buttons.
struct ActivityRow: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    let entry: ActivityEntry
    var compact = false

    var body: some View {
        Group {
            if compact {
                compactBody
            } else {
                fullBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: 13, hovering: hovering)
        .opacity(entry.isUndone ? 0.6 : 1)
        .filePreview(fileURL, highlights: false, clickQuickLooks: compact)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// The panel is narrow: the file name on one line, why, a new-name hint, then tags and small icon actions.
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                leadingIcon(size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.kind == .suggested ? fullTitle : entry.fileName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(entry.kind == .suggested ? 2 : 1)
                        .truncationMode(.middle)
                    Text(entry.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    renameHint
                }
                Spacer(minLength: 4)
                Text(TimeText.relative(entry.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if entry.kind == .suggested {
                buttons
                    .buttonStyle(.pill)
                    .padding(.leading, 36)
            } else {
                HStack(spacing: 6) {
                    tagLine
                    Spacer(minLength: 4)
                    compactActions
                }
                .padding(.leading, 36)
            }
        }
        .padding(12)
    }

    /// "New name: …", so the Rename button never has to carry the whole name.
    @ViewBuilder
    private var renameHint: some View {
        if let proposed = entry.proposedName, !entry.isUndone {
            Text("New name: \(proposed)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Small icon-only actions for the panel; hover for what each one does.
    @ViewBuilder
    private var compactActions: some View {
        if entry.isUndone {
            Text("Undone")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 2) {
                if entry.receipt != nil {
                    BarButton(symbol: "arrow.uturn.backward", help: "Undo") { model.undo(entry.id) }
                }
                if let proposed = entry.proposedName {
                    BarButton(symbol: "pencil", help: "Rename to “\(proposed)”") { model.applyProposedName(entry.id) }
                }
                if entry.kind != .renamed {
                    BarButton(symbol: "magnifyingglass", help: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.filePath)])
                    }
                }
            }
        }
    }

    /// The window has room: a big file icon, the name, why, a tag for where it went, and actions on the right.
    private var fullBody: some View {
        HStack(alignment: .top, spacing: 14) {
            leadingIcon(size: 38)
            VStack(alignment: .leading, spacing: 5) {
                nameLine
                Text(entry.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                renameHint
                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                tagLine
                if entry.kind == .suggested {
                    buttons
                        .buttonStyle(.pill)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 12) {
                Text(TimeText.relative(entry.date))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if entry.kind != .suggested {
                    actionCluster
                }
            }
        }
        .padding(14)
    }

    /// The file name, with its extension in small monospaced type.
    private var nameLine: some View {
        let name = URL(fileURLWithPath: entry.fileName)
        let ext = name.pathExtension
        let stem = ext.isEmpty ? entry.fileName : name.deletingPathExtension().lastPathComponent
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(entry.kind == .suggested ? fullTitle : stem)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .truncationMode(.middle)
            if entry.kind != .suggested, !ext.isEmpty {
                Text(".\(ext)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Where it went, and whether it went by itself.
    private var tagLine: some View {
        HStack(spacing: 6) {
            if entry.kind == .moved || entry.kind == .autoMoved || entry.kind == .learned, let name = entry.destinationName {
                Chip(text: name, symbol: "folder")
            }
            if entry.kind == .autoMoved {
                Chip(text: "Automatic", highlighted: true, symbol: "sparkle")
            }
            if entry.kind == .learned {
                Chip(text: "Learned", highlighted: true, symbol: "graduationcap")
            }
        }
    }

    /// Undo, Rename and Finder, quiet until the pointer is over the row.
    @ViewBuilder
    private var actionCluster: some View {
        if entry.isUndone {
            Text("Undone")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 10) {
                if entry.receipt != nil {
                    IconAction(title: "Undo", symbol: "arrow.uturn.backward") { model.undo(entry.id) }
                }
                if let proposed = entry.proposedName {
                    IconAction(title: "Rename", symbol: "pencil") { model.applyProposedName(entry.id) }
                        .help("Rename to “\(proposed)”")
                }
                if entry.kind != .renamed {
                    IconAction(title: "Finder", symbol: "magnifyingglass") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.filePath)])
                    }
                }
            }
            .opacity(hovering ? 1 : 0.6)
        }
    }

    /// The file type's icon, with a small spark in the skin's accent on files filed automatically.
    private func leadingIcon(size: CGFloat) -> some View {
        FileTypeIcon(fileName: entry.fileName, path: entry.filePath, size: size)
            .overlay(alignment: .topTrailing) {
                if entry.kind == .autoMoved {
                    Image(systemName: "sparkle")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(NylaStyle.brass)
                        .padding(2)
                        .background(Circle().fill(Color.black.opacity(0.75)))
                        .offset(x: 4, y: -4)
                }
            }
            .opacity(entry.isUndone ? 0.5 : 1)
            .accessibilityHidden(true)
    }

    private var fileURL: URL { URL(fileURLWithPath: entry.filePath) }

    private var symbol: String {
        switch entry.kind {
        case .autoMoved: return "sparkles"
        case .moved: return "folder.fill"
        case .renamed: return "pencil"
        case .suggested: return "questionmark.folder"
        case .learned: return "graduationcap"
        }
    }

    private var tint: Color {
        entry.kind == .suggested ? Color.orange : NylaStyle.brass
    }

    private var fullTitle: String {
        switch entry.kind {
        case .autoMoved, .moved, .renamed, .learned: return entry.fileName
        case .suggested:
            return entry.destinationName.map { "\(entry.fileName): move to \($0)?" } ?? "\(entry.fileName): a clearer name?"
        }
    }

    private var title: String {
        switch entry.kind {
        case .autoMoved: return "\(entry.fileName) → \(entry.destinationName ?? "folder") (automatic)"
        case .moved: return "\(entry.fileName) → \(entry.destinationName ?? "folder")"
        case .renamed: return entry.fileName
        case .learned: return "\(entry.fileName) → \(entry.destinationName ?? "folder") (moved in Finder)"
        case .suggested:
            return entry.destinationName.map { "\(entry.fileName): move to \($0)?" } ?? "\(entry.fileName): a clearer name?"
        }
    }

    @ViewBuilder
    private var buttons: some View {
        FlowLayout(spacing: 8) {
            if entry.isUndone {
                Text("Undone").font(.caption).foregroundStyle(.secondary)
            } else if entry.kind == .suggested {
                if let name = entry.destinationName {
                    Button("Move to \(name)") { model.acceptSuggestion(entry.id) }
                        .buttonStyle(.brass)
                }
                Menu("Other Folder") {
                    ForEach(model.favoriteFolders) { folder in
                        Button(folder.name) { model.acceptSuggestion(entry.id, destinationID: folder.id) }
                    }
                    if !model.favoriteFolders.isEmpty { Divider() }
                    Button("Any Folder…") { model.acceptSuggestionInChosenFolder(entry.id) }
                }
                .fixedSize()
                if entry.proposedName != nil {
                    Button("Rename") { model.applyProposedName(entry.id) }
                }
                Button("Dismiss") { model.dismiss(entry.id) }
            } else {
                if entry.receipt != nil {
                    Button("Undo") { model.undo(entry.id) }
                }
                if entry.proposedName != nil {
                    Button("Rename") { model.applyProposedName(entry.id) }
                }
                if entry.kind != .renamed {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.filePath)])
                    }
                }
            }
        }
    }
}

/// A Settings row: the label on the left, a switch on the right.
struct SettingToggle: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Lays views out left to right and wraps to a new line when a row is full (used for button rows).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CGFloat.infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
