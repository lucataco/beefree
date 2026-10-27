import BeeProtocol
import SwiftUI

extension Color {
    /// Honey: the app's accent, for things you can tap.
    static let honey = Color("AccentColor")
    /// The Bee's own light while it records. Green means the same thing on screen as on the Bee.
    static let recording = Color.green
    static let pairingBlue = Color(red: 0.18, green: 0.55, blue: 1.0)
    static let pairingGreen = Color(red: 0.16, green: 0.86, blue: 0.62)
}

/// The Bee itself: a graphite pebble with its button ring and status light.
struct BeeArtwork: View {
    /// Light color, or nil for off.
    var light: Color?
    /// Alternate blue and green like pairing mode.
    var pairing = false
    /// A slow ripple from the light while audio is being saved.
    var live = false

    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.30), Color(white: 0.12)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: side * 0.012)
                    )
                    .shadow(color: .black.opacity(0.25), radius: side * 0.08, y: side * 0.04)
                Circle()
                    .strokeBorder(.white.opacity(0.14), lineWidth: side * 0.025)
                    .frame(width: side * 0.46)
                Circle()
                    .fill(Color(white: 0.17))
                    .frame(width: side * 0.4)
                    .shadow(color: .black.opacity(0.4), radius: side * 0.02, y: side * 0.01)
                if live, !reduceMotion, let light = currentLight {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                        Circle()
                            .fill(light)
                            .frame(width: side * 0.07)
                            .scaleEffect(1 + t * 2.6)
                            .opacity(0.5 * (1 - t))
                    }
                    .offset(y: -side * 0.34)
                }
                Circle()
                    .fill(currentLight ?? Color(white: 0.28))
                    .frame(width: side * 0.07)
                    .shadow(color: (currentLight ?? .clear).opacity(0.9), radius: side * 0.06)
                    .offset(y: -side * 0.34)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
        .onAppear {
            guard pairing else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { phase = true }
        }
    }

    private var currentLight: Color? {
        pairing ? (phase ? .pairingGreen : .pairingBlue) : light
    }

    /// The product image for the AccessorySetupKit picker (shown in a 180 × 120 pt area).
    static func pickerImage() -> UIImage {
        let renderer = ImageRenderer(content:
            BeeArtwork(light: .pairingBlue)
                .frame(width: 110, height: 110)
                .frame(width: 180, height: 120)
        )
        renderer.scale = 3
        return renderer.uiImage ?? UIImage(systemName: "circle.fill")!
    }
}

/// The Bee's battery: "82%" with a battery symbol, colored only when it needs attention.
struct BatteryLabel: View {
    var percent: Int?
    var charging: Bool

    var body: some View {
        // Not a Label: inside a list row, a Label takes over the row's icon layout and separator.
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(percent.map { "\($0)%" } ?? "–").monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue(percent.map { "\($0) percent\(charging ? ", charging" : "")" } ?? "Unknown")
    }

    private var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch percent ?? 0 {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var tint: Color {
        guard let percent, !charging else { return charging ? .recording : .secondary }
        return percent <= 15 ? .red : percent <= 30 ? .orange : .secondary
    }
}

enum Format {
    /// "8 s", "12 min", "1 h 5 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) min" }
        if minutes >= 1 { return "\(minutes) min" }
        return "\(Int(seconds.rounded())) s"
    }
}

/// Four bars from an RSSI reading.
struct SignalBars: View {
    var rssi: Int?

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar < bars ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: 3, height: CGFloat(4 + bar * 3))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal")
        .accessibilityValue(rssi.map { "\(bars) of 4 bars, \($0) dBm" } ?? "Unknown")
    }

    static func bars(for rssi: Int?) -> Int {
        guard let rssi else { return 0 }
        switch rssi {
        case (-60)...: return 4
        case (-70)...: return 3
        case (-80)...: return 2
        default: return 1
        }
    }

    private var bars: Int { SignalBars.bars(for: rssi) }
}

extension LinkState {
    var color: Color {
        switch self {
        case .ready: .green
        case .connecting, .searching: .orange
        case .unavailable: .red
        case .unpaired: .gray
        }
    }
}


extension LogEntry.Kind {
    var symbol: String {
        switch self {
        case .button: "hand.tap.fill"
        case .state: "waveform"
        case .battery: "battery.75percent"
        case .charging: "bolt.fill"
        case .connection: "antenna.radiowaves.left.and.right"
        case .audio: "waveform.circle.fill"
        case .app: "iphone"
        case .other: "ellipsis"
        }
    }

    var color: Color {
        switch self {
        case .button: .indigo
        case .state: .honey
        case .battery: .green
        case .charging: .mint
        case .connection: .blue
        case .audio: .orange
        case .app: .teal
        case .other: .gray
        }
    }
}

/// A row with a label on the left and a value on the right that can be copied.
struct ValueRow: View {
    var title: String
    var value: String
    var monospaced = false

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .textSelection(.enabled)
        }
    }
}
