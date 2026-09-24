import GoveeLAN
import SwiftUI

/// The numbers the strip is built from, in one place so a test can ask what fits.
enum BulbStripMetrics {

    /// One tile. Wide enough for a name, a switch and a slider, narrow enough that six of
    /// them fit the window the layout was drawn for.
    static let tileWidth: CGFloat = 150
    static let tileSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 16
    static let topPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 8
    /// Two rows inside the tile, 16 and 18 points, 6 apart, with 7 points of padding top
    /// and bottom. Anything shorter clips the slider.
    static let tileHeight: CGFloat = 54

    /// Fixed, so the pane above the strip is the same height whatever is in the room.
    static var height: CGFloat { tileHeight + topPadding + bottomPadding }

    /// The room `count` tiles need. Past the width of the window they scroll sideways;
    /// they never wrap, which is Phil's ruling of 2026-09-16.
    static func contentWidth(forTileCount count: Int) -> CGFloat {
        guard count > 0 else { return horizontalPadding * 2 }
        return CGFloat(count) * tileWidth
            + CGFloat(count - 1) * tileSpacing
            + horizontalPadding * 2
    }

    /// How many tiles a chevron moves the strip along by. Three rather than one, so a
    /// long room is a few clicks away rather than a dozen, and rather than a whole page,
    /// so nothing the eye was following disappears entirely.
    static let pageStep = 3
}

/// Every bulb, along the bottom of the window, wherever you are.
///
/// One row of tiles that scrolls sideways and never wraps. The Bulbs pane does not show
/// it: the list there already is every bulb, and two copies of the same switch on one
/// screen is how a window starts looking broken.
struct BulbStripView: View {

    @Bindable var model: AppModel
    /// False only for a snapshot. `ImageRenderer` draws nothing at all inside a
    /// `ScrollView`, so an image of the window would show an empty band where the strip
    /// is. The tiles are the same tiles either way.
    var scrolls = true

    /// The bulbs the strip draws, in the one order the whole app reads. A property rather
    /// than an expression inside the body so a test can ask the strip what it would draw
    /// without rendering it.
    var tiles: [Bulb] {
        model.orderedBulbs
    }

    @State private var anchorIndex = 0
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            content(availableWidth: proxy.size.width)
        }
        .frame(height: BulbStripMetrics.height)
        .background(.quaternary.opacity(0.25))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("All bulbs")
    }

    @ViewBuilder
    private func content(availableWidth: CGFloat) -> some View {
        let bulbs = tiles
        if bulbs.isEmpty {
            Text(model.networkUnavailable ? "Network unavailable." : "No bulbs found yet.")
                .font(PartyStyle.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, BulbStripMetrics.horizontalPadding)
        } else {
            let overflows = BulbStripMetrics.contentWidth(forTileCount: bulbs.count)
                > availableWidth
            if scrolls {
                ScrollViewReader { scroller in
                    ScrollView(.horizontal) {
                        row(bulbs: bulbs)
                    }
                    .scrollIndicators(.never)
                    .scrollDisabled(!overflows)
                    .overlay(alignment: .leading) {
                        chevron(.backward, bulbs: bulbs, isShown: overflows, scroller: scroller)
                    }
                    .overlay(alignment: .trailing) {
                        chevron(.forward, bulbs: bulbs, isShown: overflows, scroller: scroller)
                    }
                }
            } else {
                row(bulbs: bulbs)
            }
        }
    }

    private func row(bulbs: [Bulb]) -> some View {
        LazyHStack(spacing: BulbStripMetrics.tileSpacing) {
            ForEach(Array(bulbs.enumerated()), id: \.element.id) { entry in
                BulbStripTile(model: model, bulb: entry.element, index: entry.offset)
                    .id(entry.element.id)
            }
        }
        .padding(.horizontal, BulbStripMetrics.horizontalPadding)
        .padding(.top, BulbStripMetrics.topPadding)
        .padding(.bottom, BulbStripMetrics.bottomPadding)
    }

    private enum Direction {
        case backward
        case forward

        var symbol: String {
            self == .backward ? "chevron.left" : "chevron.right"
        }

        var label: String {
            self == .backward ? "Earlier bulbs" : "Later bulbs"
        }
    }

    /// Only while the mouse is over the strip and only when there is something off the
    /// end of it. A chevron that is always there on a row that always fits is a control
    /// that can never do anything.
    @ViewBuilder
    private func chevron(_ direction: Direction,
                         bulbs: [Bulb],
                         isShown: Bool,
                         scroller: ScrollViewProxy) -> some View {
        let target = destination(direction, count: bulbs.count)
        Button {
            guard let target else { return }
            anchorIndex = target
            withAnimation(PartyStyle.motion(PartyStyle.calm, reduceMotion: reduceMotion)) {
                scroller.scrollTo(bulbs[target].id, anchor: .leading)
            }
        } label: {
            Image(systemName: direction.symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: BulbStripMetrics.tileHeight)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .padding(.horizontal, 4)
        .opacity(isShown && isHovering && target != nil ? 1 : 0)
        .animation(PartyStyle.motion(PartyStyle.quick, reduceMotion: reduceMotion),
                   value: isHovering)
        .accessibilityLabel(direction.label)
        .accessibilityHidden(!isShown)
        .allowsHitTesting(isShown)
    }

    /// The tile a chevron scrolls to, or nil when there is nothing that way.
    private func destination(_ direction: Direction, count: Int) -> Int? {
        let step = BulbStripMetrics.pageStep
        switch direction {
        case .backward:
            guard anchorIndex > 0 else { return nil }
            return max(0, anchorIndex - step)
        case .forward:
            let next = anchorIndex + step
            guard next < count else { return nil }
            return next
        }
    }
}
