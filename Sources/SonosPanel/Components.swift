import SwiftUI

enum Theme {
    static let bg = Color(white: 0.055)
    static let tile = Color(white: 0.115)
    static let tileHover = Color(white: 0.16)
    static let stroke = Color.white.opacity(0.06)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.35)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
    }
}

struct CircleButton: View {
    let symbol: String
    var size: CGFloat = 40
    var tint: Color = .white
    var highlighted = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(highlighted ? Color.white.opacity(0.18) : (hover ? Theme.tileHover : Theme.tile))
                )
                .overlay(Circle().stroke(Theme.stroke))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A 4-up control tile: icon, title, value; optional chevron (menu) or dot (state).
struct ControlTile: View {
    let symbol: String
    let title: String
    let value: String
    var chevron = false
    var dot: Bool? = nil
    var action: () -> Void = {}
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .light))
                        .frame(height: 24)
                    Spacer(minLength: 0)
                    if chevron {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                    } else if let dot {
                        Circle().fill(dot ? Color.green : Theme.tertiary).frame(width: 6, height: 6)
                    }
                }
                Spacer(minLength: 0)
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Text(value).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .background(hover ? Theme.tileHover : Theme.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Tile that opens a popover with a list of choices.
struct ChoiceTile: View {
    let symbol: String
    let title: String
    let value: String
    let choices: [(id: String, label: String, symbol: String?)]
    var isSelected: (String) -> Bool = { _ in false }
    /// Keeps the popover open after a pick (multi-select lists like grouping).
    var keepOpen = false
    let onPick: (String) -> Void
    @State private var open = false

    var body: some View {
        ControlTile(symbol: symbol, title: title, value: value, chevron: !choices.isEmpty) {
            if !choices.isEmpty { open.toggle() }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(choices, id: \.id) { choice in
                    Button {
                        if !keepOpen { open = false }
                        onPick(choice.id)
                    } label: {
                        HStack(spacing: 8) {
                            if let s = choice.symbol { Image(systemName: s).frame(width: 18) }
                            Text(choice.label)
                            Spacer()
                            if isSelected(choice.id) { Image(systemName: "checkmark").font(.caption) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(minWidth: 200)
        }
    }
}

/// Wide frosted slider like the reference design: soft gradient fill and a pill-shaped knob.
struct GlassSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var enabled = true
    var height: CGFloat = 46
    var onChange: (Double) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let knobW: CGFloat = height < 40 ? 18 : 26
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let x = (geo.size.width - knobW) * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.09))
                Capsule()
                    .fill(LinearGradient(colors: [Color.white.opacity(0.04), Color.white.opacity(0.38)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: x + knobW)
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [.white, Color(white: 0.82)], startPoint: .top, endPoint: .bottom))
                    .frame(width: knobW, height: geo.size.height - (height < 40 ? 6 : 10))
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                    .offset(x: x)
            }
            .overlay(Capsule().stroke(Theme.stroke))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    guard enabled else { return }
                    let f = min(1, max(0, (g.location.x - knobW / 2) / (geo.size.width - knobW)))
                    let v = (range.lowerBound + f * (range.upperBound - range.lowerBound)).rounded()
                    if v != value { onChange(v) }
                }
            )
        }
        .frame(height: height)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// Large device glyph with a soft glow, standing in for the product render.
struct HeroGlyph: View {
    let symbol: String
    var active = true
    var animate = false
    var caption: String? = nil

    var body: some View {
        ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [Color.white.opacity(active ? 0.16 : 0.05), .clear],
                                     center: .center, startRadius: 4, endRadius: 110))
                .frame(width: 240, height: 110)
                .blur(radius: 8)
            Image(systemName: symbol)
                .font(.system(size: 86, weight: .ultraLight))
                .foregroundStyle(LinearGradient(colors: [.white, Color(white: active ? 0.7 : 0.35)],
                                                startPoint: .top, endPoint: .bottom))
                .symbolEffect(.pulse, options: .repeating, isActive: animate)
            if let caption {
                Text(caption)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .overlay(Capsule().stroke(Theme.stroke))
                    .offset(y: 50)
            }
        }
        .frame(height: 124)
        .frame(maxWidth: .infinity)
    }
}

struct BigReadout: View {
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit).font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.secondary)
        }
    }
}

struct Footer: View {
    let symbol: String
    let text: String
    var tint: Color = Theme.secondary
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).font(.system(size: 11)).lineLimit(1)
            Spacer()
            Button(action: onSettings) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 2)
    }
}

/// Pill toggle matching the panel style (also renders in ImageRenderer, unlike the system switch).
struct PillSwitch: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(isOn ? Color.white.opacity(0.85) : Color(white: 0.24))
                .frame(width: 40, height: 23)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(isOn ? Color.black.opacity(0.85) : .white).padding(3)
                }
                .animation(.snappy(duration: 0.15), value: isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Left-aligned wrapping row, used by the device switcher.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
