import AppKit
import SwiftUI

/// 主窗口 v7 的配色：外框、卡片、墨色层级都由预设的主色按 oklch 推出，浅色和深色各一套。
/// 数值照抄设计稿 `deliverables/Westie/reviews/2026-10-27-main-window/v7/source/index.html` 的 `paint()`。
struct Palette {
    struct Hue {
        var h: Double
        var c: Double
    }

    /// 预设“雾”：相近的两种暖灰。
    static let mist = [Hue(h: 75, c: 0.022), Hue(h: 60, c: 0.016)]

    let dark: Bool
    let ink, ink2, ink3, ink4, ink5: Color
    let accent, onAccent, warn, ok, bad: Color
    let rowHover, rowHoverSolid, rowOn, rowOnStroke: Color
    let card, cardStroke, cardShadowNear, cardShadowFar: Color
    let bubble, code, box, boxStroke, boxShadow: Color
    /// 加载占位条。
    let placeholder: Color
    /// 拖放预览：半透明的卡片底和一圈强调色描边。
    let preview, previewRing: Color
    let frameBase: Color
    /// 外框的两团晕色：颜色和中心位置。
    let frameGlows: [(color: Color, center: UnitPoint)]

    init(colors: [Hue] = Palette.mist, dark: Bool) {
        self.dark = dark
        let h0 = colors[0].h
        let ok = Self.oklch
        ink = dark ? ok(0.95, 0.008, h0, 1) : ok(0.23, 0.02, h0, 1)
        ink2 = dark ? ok(0.82, 0.01, h0, 1) : ok(0.38, 0.02, h0, 1)
        ink3 = dark ? ok(0.66, 0.012, h0, 1) : ok(0.52, 0.02, h0, 1)
        ink4 = dark ? ok(0.5, 0.01, h0, 1) : ok(0.68, 0.015, h0, 1)
        ink5 = dark ? ok(0.4, 0.01, h0, 1) : ok(0.84, 0.012, h0, 1)
        let chroma = max(0.04, min(0.16, colors[0].c * 1.8))
        accent = dark ? ok(0.76, chroma, h0, 1) : ok(0.5, chroma, h0, 1)
        onAccent = dark ? ok(0.2, 0.02, h0, 1) : .white
        warn = dark ? ok(0.8, 0.14, 75, 1) : ok(0.74, 0.15, 70, 1)
        self.ok = dark ? ok(0.78, 0.13, 150, 1) : ok(0.55, 0.13, 150, 1)
        bad = dark ? ok(0.74, 0.14, 25, 1) : ok(0.56, 0.17, 25, 1)
        rowHover = dark ? .white.opacity(0.06) : .white.opacity(0.32)
        rowHoverSolid = dark ? .white.opacity(0.06) : .black.opacity(0.04)
        rowOn = dark ? .white.opacity(0.1) : .white.opacity(0.72)
        rowOnStroke = dark ? .clear : ok(0.4, 0.04, h0, 0.1)
        card = dark ? ok(0.205, 0.012, h0, 1) : ok(0.988, 0.006, h0, 1)
        cardStroke = dark ? .white.opacity(0.08) : ok(0.4, 0.04, h0, 0.16)
        cardShadowNear = dark ? .black.opacity(0.35) : ok(0.3, 0.05, h0, 0.06)
        cardShadowFar = dark ? .black.opacity(0.4) : ok(0.3, 0.06, h0, 0.12)
        placeholder = dark ? .white.opacity(0.07) : ok(0.4, 0.03, h0, 0.09)
        bubble = dark ? ok(0.27, 0.02, h0, 1) : ok(0.95, 0.016, h0, 1)
        code = dark ? ok(0.17, 0.01, h0, 1) : ok(0.965, 0.008, h0, 1)
        box = dark ? ok(0.24, 0.014, h0, 1) : .white
        boxStroke = dark ? .white.opacity(0.1) : ok(0.4, 0.04, h0, 0.18)
        boxShadow = dark ? .black.opacity(0.3) : ok(0.3, 0.06, h0, 0.12)
        preview = dark ? ok(0.3, 0.02, h0, 0.72) : ok(0.99, 0.006, h0, 0.78)
        previewRing = dark ? ok(0.76, chroma, h0, 0.55) : ok(0.5, chroma, h0, 0.45)

        let lightness = dark ? 0.26 : 0.925, scale = dark ? 0.7 : 0.55
        frameBase = ok(lightness, colors[0].c * 0.8 * scale, h0, 1)
        let centers = [UnitPoint(x: 0.06, y: 0.08), UnitPoint(x: 0.14, y: 0.96), UnitPoint(x: 0.96, y: 0.06)]
        frameGlows = colors.prefix(centers.count).enumerated().map { index, hue in
            (ok(dark ? lightness + 0.025 : lightness - 0.03, hue.c * scale, hue.h, 0.9), centers[index])
        }
    }

    /// oklch → sRGB（Björn Ottosson 的 Oklab 矩阵）。
    static func oklch(_ l: Double, _ c: Double, _ h: Double, _ alpha: Double) -> Color {
        let radians = h * .pi / 180
        let a = c * cos(radians), b = c * sin(radians)
        let l1 = l + 0.3963377774 * a + 0.2158037573 * b
        let m1 = l - 0.1055613458 * a - 0.0638541728 * b
        let s1 = l - 0.0894841775 * a - 1.2914855480 * b
        let (lc, mc, sc) = (l1 * l1 * l1, m1 * m1 * m1, s1 * s1 * s1)
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        return Color(
            .sRGBLinear,
            red: clamp(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc),
            green: clamp(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc),
            blue: clamp(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc),
            opacity: alpha
        )
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(dark: false)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// 外框：底色 + 两团晕色 + 一层静态颗粒（只生成一次）。
struct FrameBackground: View {
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            palette.frameBase
            ForEach(Array(palette.frameGlows.enumerated()), id: \.offset) { _, glow in
                EllipticalGradient(colors: [glow.color, glow.color.opacity(0)], center: glow.center, endRadiusFraction: 0.72)
            }
            Image(decorative: Self.grain, scale: 2)
                .resizable(resizingMode: .tile)
                .blendMode(palette.dark ? .softLight : .overlay)
                .opacity(0.22)
            AppMoveArea()
        }
        .ignoresSafeArea()
    }

    private static let grain: CGImage = {
        let side = 320
        var pixels = [UInt8](repeating: 0, count: side * side)
        for index in pixels.indices { pixels[index] = UInt8.random(in: 0...255) }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }()
}

extension View {
    /// 内容卡片：近白带色调、0.5pt 描边、近距柔和阴影，“嵌”在外框上。
    func card(_ palette: Palette, radius: CGFloat = Metrics.cardRadius) -> some View {
        background(palette.card, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(palette.cardStroke, lineWidth: 0.5))
            .clipShape(.rect(cornerRadius: radius))
            .shadow(color: palette.cardShadowNear, radius: 1, y: 1)
            .shadow(color: palette.cardShadowFar, radius: 6, y: 4)
    }
}

/// App 图标（西高地，App/Westie/Westie.icon），用在会话列表标题和启动画面。
/// 图标画布四周自带留白，size 指整个画布。
struct AppLogo: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum Metrics {
    /// 外框留白，也是面板之间、窗口之间的缝。
    static let gap: CGFloat = 8
    /// 卡片圆角 = 窗口圆角 16 − 外框留白 + 2（同设计稿）。
    static let cardRadius: CGFloat = 10
    static let rowRadius: CGFloat = 6
    /// 红绿灯那一行的高度。
    static let lightsHeight: CGFloat = 40
}
