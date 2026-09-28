import AppKit
import SwiftUI

let variantNames = ["Workbench", "Journal", "Editorial"]

struct Harness: View {
    @AppStorage("proto.identity.v") private var stored = 1
    @State private var current = 0
    @State private var keyMonitor: Any?

    var body: some View {
        Group {
            switch current {
            case 0: WorkbenchVariant()
            case 1: JournalVariant()
            default: EditorialVariant()
            }
        }
        .id(current)
        .overlay(alignment: .bottom) {
            ProtoPicker(names: variantNames, current: $current)
                .padding(.bottom, 24)
        }
        .onAppear {
            let env = ProcessInfo.processInfo.environment["PROTO_V"].flatMap(Int.init)
            current = min(max((env ?? stored) - 1, 0), variantNames.count - 1)
            installKeys()
        }
        .onChange(of: current) { stored = current + 1 }
    }

    /// 1–N and ←/→ switch variants; ignored while typing or with modifiers held.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }
            let count = variantNames.count
            if let chars = event.charactersIgnoringModifiers, let number = Int(chars), (1...count).contains(number) {
                current = number - 1
                return nil
            }
            switch event.keyCode {
            case 124: current = (current + 1) % count; return nil
            case 123: current = (current - 1 + count) % count; return nil
            default: return event
            }
        }
    }
}

/// Harness chrome from PICKER.md: dark pill, bottom-center, not theme-aware.
struct ProtoPicker: View {
    let names: [String]
    @Binding var current: Int
    @Namespace private var namespace
    @State private var ready = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(names.indices, id: \.self) { index in
                ProtoPickerItem(title: names[index], isActive: index == current, namespace: namespace) { current = index }
            }
        }
        .padding(4)
        .background {
            Capsule()
                .fill(Color(.sRGB, red: 10 / 255, green: 10 / 255, blue: 10 / 255, opacity: 0.82))
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.24), radius: 12, y: 8)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
        }
        .environment(\.colorScheme, .dark)
        .animation(ready && !reduceMotion ? .timingCurve(0.23, 1, 0.32, 1, duration: 0.25) : nil, value: current)
        .onAppear { DispatchQueue.main.async { ready = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Prototype variants")
    }
}

private struct ProtoPickerItem: View {
    let title: String
    let isActive: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .foregroundStyle(.white.opacity(isActive ? 1 : hovering ? 0.85 : 0.55))
                .background {
                    if isActive { Capsule().fill(.white.opacity(0.12)).matchedGeometryEffect(id: "highlight", in: namespace) }
                }
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
