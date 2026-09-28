import AppKit
import SwiftUI

/// A color expressed in OKLCH. Lightness 0...1, chroma ~0...0.4, hue in degrees.
public struct OKLCH: Sendable, Hashable {
    public var l: Double
    public var c: Double
    public var h: Double
    public var alpha: Double

    public init(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1) {
        self.l = l
        self.c = c
        self.h = h
        self.alpha = alpha
    }

    public var isInSRGBGamut: Bool {
        let rgb = Self.toLinearSRGB(l: l, c: c, h: h)
        let range = -1e-6...(1 + 1e-6)
        return range.contains(rgb.r) && range.contains(rgb.g) && range.contains(rgb.b)
    }

    /// Largest chroma at this lightness and hue that still fits sRGB.
    public static func maxChroma(l: Double, h: Double) -> Double {
        var low = 0.0
        var high = 0.4
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if OKLCH(l, mid, h).isInSRGBGamut { low = mid } else { high = mid }
        }
        return low
    }

    /// A tone at lightness `l` with `fraction` of the hue's own chroma ceiling, so sibling hues read equally vivid.
    public static func tone(l: Double, h: Double, fraction: Double) -> OKLCH {
        OKLCH(l, maxChroma(l: l, h: h) * fraction, h)
    }

    /// Chroma is reduced (L and H held) until the color fits sRGB.
    public var gamutMapped: OKLCH {
        isInSRGBGamut ? self : OKLCH(l, min(c, Self.maxChroma(l: l, h: h)), h, alpha: alpha)
    }

    public var nsColor: NSColor {
        let mapped = gamutMapped
        let rgb = Self.toLinearSRGB(l: mapped.l, c: mapped.c, h: mapped.h)
        return NSColor(
            colorSpace: .sRGB,
            components: [Self.encode(rgb.r), Self.encode(rgb.g), Self.encode(rgb.b), alpha],
            count: 4
        )
    }

    public func opacity(_ value: Double) -> OKLCH { OKLCH(l, c, h, alpha: value) }

    private static func toLinearSRGB(l: Double, c: Double, h: Double) -> (r: Double, g: Double, b: Double) {
        let radians = h * .pi / 180
        let a = c * cos(radians)
        let b = c * sin(radians)
        let l1 = l + 0.3963377774 * a + 0.2158037573 * b
        let m1 = l - 0.1055613458 * a - 0.0638541728 * b
        let s1 = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = l1 * l1 * l1
        let mc = m1 * m1 * m1
        let sc = s1 * s1 * s1
        return (
            4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
            -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
            -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
        )
    }

    private static func encode(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }
}

public extension Color {
    /// A color that resolves to `light` or `dark` with the current appearance.
    init(light: OKLCH, dark: OKLCH) {
        let lightColor = light.nsColor
        let darkColor = dark.nsColor
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }

    init(_ oklch: OKLCH) {
        self.init(nsColor: oklch.nsColor)
    }
}
