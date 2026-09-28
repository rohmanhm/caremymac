import SwiftUI

/// The monitored resources. Each owns one hue; every tone of it keeps that hue.
public enum Resource: String, CaseIterable, Sendable, Identifiable {
    case cpu, memory, disk, network, storage, graphics, battery

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .storage: "Storage"
        case .graphics: "Graphics"
        case .battery: "Battery"
        }
    }

    public var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .storage: "chart.pie"
        case .graphics: "cube.transparent"
        case .battery: "battery.75percent"
        }
    }

    /// OKLCH hue angle.
    public var hue: Double {
        switch self {
        case .cpu: 255
        case .memory: 300
        case .disk: 62
        case .network: 200
        case .storage: 230
        case .graphics: 345
        case .battery: 150
        }
    }

    /// Primary series and icon tint.
    public var color: Color { tones.primary }
    /// Secondary series (disk write, upload).
    public var secondaryColor: Color { tones.secondary }
    /// Low-chroma wash for fills behind content.
    public var wash: Color { tones.wash }
    /// Text-safe tone.
    public var textColor: Color { tones.text }

    private var tones: Palette.Tones { Palette.resourceTones[self] ?? Palette.Tones(hue: hue) }
}

public enum Palette {
    struct Tones {
        let primary: Color
        let secondary: Color
        let wash: Color
        let text: Color

        init(hue: Double) {
            primary = Palette.primary(hue: hue)
            secondary = Palette.secondary(hue: hue)
            wash = Palette.wash(hue: hue)
            text = Palette.text(hue: hue)
        }
    }

    static let resourceTones: [Resource: Tones] = Dictionary(uniqueKeysWithValues: Resource.allCases.map { ($0, Tones(hue: $0.hue)) })

    // Light: L 0.58 at 90% of the hue's chroma ceiling. Dark: lifted to L 0.74 and desaturated to 72%
    // so the same hue doesn't vibrate on a dark ground.
    public static func primary(hue: Double) -> Color {
        Color(light: .tone(l: 0.58, h: hue, fraction: 0.9), dark: .tone(l: 0.74, h: hue, fraction: 0.72))
    }

    public static func secondary(hue: Double) -> Color {
        Color(light: .tone(l: 0.74, h: hue, fraction: 0.62), dark: .tone(l: 0.86, h: hue, fraction: 0.5))
    }

    public static func wash(hue: Double) -> Color {
        Color(light: .tone(l: 0.96, h: hue, fraction: 0.35), dark: .tone(l: 0.26, h: hue, fraction: 0.3))
    }

    /// Text-safe tone of a hue (passes 4.5:1 on window backgrounds in both modes).
    public static func text(hue: Double) -> Color {
        Color(light: .tone(l: 0.48, h: hue, fraction: 0.9), dark: .tone(l: 0.80, h: hue, fraction: 0.6))
    }

    public static let live = primary(hue: 150)
    public static let warning = Color(light: .tone(l: 0.62, h: 70, fraction: 0.95), dark: .tone(l: 0.80, h: 75, fraction: 0.8))
    public static let warningText = Color(light: .tone(l: 0.50, h: 60, fraction: 0.95), dark: .tone(l: 0.82, h: 75, fraction: 0.75))
    public static let critical = Color(light: .tone(l: 0.56, h: 25, fraction: 0.9), dark: .tone(l: 0.70, h: 25, fraction: 0.75))
}
