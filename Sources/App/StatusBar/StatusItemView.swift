import AppKit
import SpeedCore

/// What the menu bar draws. Sendable snapshot so the controller can hand it over wholesale.
struct StatusItemRenderModel: Equatable {
    var downText: String = "0.0"
    var upText: String = "0.0"
    var state: ConnectionDisplayState = .unknown
    var layout: BarLayout = .twoLine
    var showUnits: Bool = false
    var unit: SpeedUnit = .megabitsPerSecond
}

enum BarLayout: String, CaseIterable, Codable {
    case twoLine
    case oneLine
    case dotOnly

    var title: String {
        switch self {
        case .twoLine: return "Two lines"
        case .oneLine: return "One line"
        case .dotOnly: return "Dot only"
        }
    }
}

/// Custom NSView hosted inside the status button.
///
/// Deliberately not `button.attributedTitle`: a two-line attributed title clips, its line
/// height is wrong, and it needs a different baseline offset on built-in versus external
/// displays. Drawing directly avoids all of that.
final class StatusItemView: NSView {
    var model = StatusItemRenderModel() {
        didSet {
            guard model != oldValue else { return }
            needsDisplay = true
            updateAccessibility()
        }
    }

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    static let oneLineFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private let dotDiameter: CGFloat = 6
    private let horizontalPadding: CGFloat = 4
    private let dotGap: CGFloat = 4

    override var isFlipped: Bool { false }

    // MARK: - Sizing

    /// Width is pinned to the widest string the layout can ever produce, so the whole
    /// right side of the menu bar does not shuffle every second. Monospaced digits alone
    /// do not achieve this: they equalise glyph widths, not string lengths.
    static func width(for layout: BarLayout, showUnits: Bool, unit: SpeedUnit) -> CGFloat {
        let dot: CGFloat = 6 + 4
        let padding: CGFloat = 8

        switch layout {
        case .dotOnly:
            return padding + dot + 6
        case .oneLine:
            let sample = "↓ \(widestNumber(unit: unit)) ↑ \(widestNumber(unit: unit))" + (showUnits ? " \(unit.shortLabel)" : "")
            return padding + dot + measure(sample, font: oneLineFont)
        case .twoLine:
            let sample = "↓ \(widestNumber(unit: unit))" + (showUnits ? " \(unit.shortLabel)" : "")
            return padding + dot + measure(sample, font: font)
        }
    }

    private static func widestNumber(unit: SpeedUnit) -> String {
        SpeedFormatter.widestBarSamples(unit: unit)
            .max(by: { measure($0, font: font) < measure($1, font: font) }) ?? "999.9"
    }

    private static func measure(_ string: String, font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width) + 2
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let textColor: NSColor = model.state.textIsRed ? .systemRed : .labelColor
        drawDot()

        switch model.layout {
        case .dotOnly:
            return
        case .oneLine:
            let unitSuffix = model.showUnits ? " \(model.unit.shortLabel)" : ""
            let text = "↓ \(model.downText) ↑ \(model.upText)\(unitSuffix)"
            draw(text, font: Self.oneLineFont, color: textColor, centeredVerticallyIn: bounds)
        case .twoLine:
            let unitSuffix = model.showUnits ? " \(model.unit.shortLabel)" : ""
            let rowHeight = bounds.height / 2
            draw("↓ \(model.downText)\(unitSuffix)", font: Self.font, color: textColor,
                 rightAlignedIn: NSRect(x: 0, y: rowHeight - 1, width: bounds.width - horizontalPadding, height: rowHeight))
            draw("↑ \(model.upText)\(unitSuffix)", font: Self.font, color: textColor,
                 rightAlignedIn: NSRect(x: 0, y: 1, width: bounds.width - horizontalPadding, height: rowHeight))
        }
    }

    private func drawDot() {
        let y = (bounds.height - dotDiameter) / 2
        let rect = NSRect(x: horizontalPadding, y: y, width: dotDiameter, height: dotDiameter)
        model.state.dotColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, rightAlignedIn rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let y = rect.minY + (rect.height - size.height) / 2
        (text as NSString).draw(
            in: NSRect(x: rect.minX, y: y, width: rect.width, height: size.height),
            withAttributes: attributes
        )
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, centeredVerticallyIn rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let y = rect.minY + (rect.height - size.height) / 2
        (text as NSString).draw(
            in: NSRect(x: rect.minX, y: y, width: rect.width - horizontalPadding, height: size.height),
            withAttributes: attributes
        )
    }

    // MARK: - Accessibility

    private func updateAccessibility() {
        setAccessibilityLabel("Internet speed")
        setAccessibilityValue(
            "Download \(model.downText), upload \(model.upText) \(model.unit.shortLabel), \(model.state.spokenDescription)"
        )
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
}
