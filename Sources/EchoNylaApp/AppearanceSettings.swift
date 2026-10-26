import AppKit
import EchoNylaCore
import SwiftUI

/// Settings > Appearance: Verbyn's six skins, light or dark, and whether the app icon follows the skin.
struct AppearanceSettings: View {
    var body: some View {
        let store = SkinStore.shared
        GroupBox("Appearance") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Light or dark", selection: Binding(
                    get: { store.preference.appearance },
                    set: { store.setAppearance($0) }
                )) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(Skin.allCases, id: \.self) { skin in
                        SkinTile(skin: skin)
                    }
                }
                SettingToggle("App icon follows the skin", isOn: Binding(
                    get: { store.preference.iconFollowsSkin },
                    set: { store.setIconFollowsSkin($0) }
                ))
                Caption("The same six skins as Verbyn, each light and dark. Skins change colors and the icon only; how files are filed never changes.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

/// One skin in the Settings grid: its dark and light versions side by side, its name, and whether it's in use.
struct SkinTile: View {
    let skin: Skin

    var body: some View {
        let store = SkinStore.shared
        let chosen = store.skin == skin
        Button {
            store.select(skin)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 0) {
                    miniature(dark: true, sidebarWidth: 16)
                    miniature(dark: false, sidebarWidth: 0)
                }
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.gray.opacity(0.3), lineWidth: 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text(skin.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(chosen ? "In use" : skin.tagline)
                        .font(.system(size: 10.5))
                        .foregroundStyle(chosen ? NylaStyle.brass : Color.secondary)
                        .lineLimit(1)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NylaStyle.wash(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(chosen ? NylaStyle.brass : NylaStyle.hairline, lineWidth: chosen ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(skin.displayName), \(skin.tagline)")
        .accessibilityAddTraits(chosen ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    /// A sidebar, a title line, a body line and an accent button.
    private func miniature(dark: Bool, sidebarWidth: CGFloat) -> some View {
        let palette = skin.palette(dark: dark)
        let text = dark ? Color.white.opacity(0.85) : Color.black.opacity(0.8)
        return HStack(spacing: 0) {
            if sidebarWidth > 0 {
                Rectangle()
                    .fill(Color(palette.sidebar))
                    .frame(width: sidebarWidth)
            }
            ZStack(alignment: .topLeading) {
                Color(palette.window)
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(text).frame(width: 30, height: 4)
                    Capsule().fill(text.opacity(0.4)).frame(width: 40, height: 3)
                    Capsule().fill(Color(palette.accent)).frame(width: 22, height: 6)
                }
                .padding(8)
            }
        }
    }
}

/// The Apple Intelligence mark in the sidebar card: the seven interlaced loops of the supplied artwork
/// (Resources/IntelligenceLoops.png, cut from IntelligenceMark.png) on a small tile, both in the
/// skin's colours: silver loops on black in dark Signature, the skin's accent shades elsewhere. If
/// the file is missing (a build run outside the packaged app), drawn loops are used instead.
struct IntelligenceMark: View {
    var available = true

    private static let loops: NSImage? = Bundle.main.url(forResource: "IntelligenceLoops", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tileFill)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(NylaStyle.hairline, lineWidth: 1))
            loopFill
                .mask { loopShape }
                .padding(2)
        }
        .frame(width: 34, height: 34)
        .shadow(color: Color.black.opacity(NylaStyle.isDark ? 0.4 : 0.12), radius: 3, y: 1)
        .saturation(available ? 1 : 0)
        .opacity(available ? 1 : 0.5)
        .accessibilityHidden(true)
    }

    /// A step lighter than the cards in dark mode, white in light mode.
    private var tileFill: Color {
        NylaStyle.isDark ? Color(SkinStore.shared.palette.surface.mixed(with: RGB(hex: 0xFFFFFF), amount: 0.06)) : Color.white
    }

    @ViewBuilder
    private var loopFill: some View {
        if NylaStyle.isSignature && NylaStyle.isDark {
            NylaStyle.silver
        } else {
            LinearGradient(colors: NylaStyle.accentGradient, startPoint: .top, endPoint: .bottom)
        }
    }

    @ViewBuilder
    private var loopShape: some View {
        if let loops = Self.loops {
            Image(nsImage: loops)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
        } else {
            rosette.padding(4)
        }
    }

    /// Seven ellipses turned round the centre, so each crosses its neighbours and the middle stays open.
    private var rosette: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                ForEach(0..<7, id: \.self) { index in
                    ZStack {
                        Ellipse()
                            .stroke(Color.black, lineWidth: side * 0.06)
                            .frame(width: side * 0.59, height: side * 0.22)
                            .offset(y: -side * 0.25)
                    }
                    .frame(width: side, height: side)
                    .rotationEffect(.degrees(Double(index) * 360.0 / 7.0))
                }
            }
            .frame(width: side, height: side)
        }
    }
}
