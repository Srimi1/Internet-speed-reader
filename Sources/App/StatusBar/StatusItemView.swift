import AppKit
import SpeedCore

/// How prominently one direction's row is drawn.
enum RowEmphasis: Equatable {
    /// Nothing is transferring in either direction: both rows look the same.
    case normal
    /// This direction is transferring right now.
    case active
    /// The other direction is transferring; this one recedes without disappearing.
    case muted
}

/// What the menu bar draws. Sendable snapshot so the controller can hand it over wholesale.
struct StatusItemRenderModel: Equatable {
    var downText: String = SpeedFormatter.unavailable
    var upText: String = SpeedFormatter.unavailable
    var downEmphasis: RowEmphasis = .normal
    var upEmphasis: RowEmphasis = .normal
    /// Dimmed while a reading is briefly being re-established, so a rebaseline does not
    /// blank the bar. Unavailable draws the dash.
    var freshness: LiveReadoutModel.Freshness = .unavailable
    /// Which direction the adaptive layout is showing right now.
    var activeDirection: TrafficDirection = .download
    var state: ConnectionDisplayState = .unknown
    var layout: BarLayout = .twoLine
    var showUnits: Bool = false
    var unit: SpeedUnit = .megabitsPerSecond
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
    /// The active row is drawn heavier, so the widest string must be measured with this
    /// font or the pinned width would be too small the moment a transfer starts.
    static let emphasisFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    static let oneLineFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let oneLineEmphasisFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

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
        case .adaptive:
            let sample = "↓ \(widestNumber(unit: unit, font: oneLineEmphasisFont))" + (showUnits ? " \(unit.shortLabel)" : "")
            return padding + dot + measure(sample, font: oneLineEmphasisFont)
        case .oneLine:
            let number = widestNumber(unit: unit, font: oneLineEmphasisFont)
            let sample = "↓ \(number) ↑ \(number)" + (showUnits ? " \(unit.shortLabel)" : "")
            return padding + dot + measure(sample, font: oneLineEmphasisFont)
        case .twoLine:
            let sample = "↓ \(widestNumber(unit: unit, font: emphasisFont))" + (showUnits ? " \(unit.shortLabel)" : "")
            return padding + dot + measure(sample, font: emphasisFont)
        }
    }

    /// Selection and measurement must use the same font, or the sample chosen as widest
    /// at one weight is not the widest at the weight actually drawn.
    private static func widestNumber(unit: SpeedUnit, font: NSFont) -> String {
        SpeedFormatter.widestBarSamples(unit: unit)
            .max(by: { measure($0, font: font) < measure($1, font: font) }) ?? "999.9"
    }

    private static func measure(_ string: String, font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width) + 2
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawDot()

        switch model.layout {
        case .dotOnly:
            return
        case .adaptive:
            let unitSuffix = model.showUnits ? " \(model.unit.shortLabel)" : ""
            let isUpload = model.activeDirection == .upload
            let arrow = isUpload ? "↑" : "↓"
            let number = isUpload ? model.upText : model.downText
            let emphasis = isUpload ? model.upEmphasis : model.downEmphasis
            draw("\(arrow) \(number)\(unitSuffix)", font: font(for: emphasis, oneLine: true),
                 color: color(for: emphasis), centeredVerticallyIn: bounds)
        case .oneLine:
            let unitSuffix = model.showUnits ? " \(model.unit.shortLabel)" : ""
            // One row, so the heavier of the two emphases sets the font; colour still
            // distinguishes the two halves through the attributed string below.
            let text = "↓ \(model.downText) ↑ \(model.upText)\(unitSuffix)"
            let emphasis: RowEmphasis = model.downEmphasis == .active || model.upEmphasis == .active ? .active : .normal
            draw(text, font: font(for: emphasis, oneLine: true), color: color(for: .normal),
                 centeredVerticallyIn: bounds)
        case .twoLine:
            let unitSuffix = model.showUnits ? " \(model.unit.shortLabel)" : ""
            let rowHeight = bounds.height / 2
            draw("↓ \(model.downText)\(unitSuffix)", font: font(for: model.downEmphasis, oneLine: false),
                 color: color(for: model.downEmphasis),
                 rightAlignedIn: NSRect(x: 0, y: rowHeight - 1, width: bounds.width - horizontalPadding, height: rowHeight))
            draw("↑ \(model.upText)\(unitSuffix)", font: font(for: model.upEmphasis, oneLine: false),
                 color: color(for: model.upEmphasis),
                 rightAlignedIn: NSRect(x: 0, y: 1, width: bounds.width - horizontalPadding, height: rowHeight))
        }
    }

    private func font(for emphasis: RowEmphasis, oneLine: Bool) -> NSFont {
        switch (emphasis, oneLine) {
        case (.active, true): return Self.oneLineEmphasisFont
        case (.active, false): return Self.emphasisFont
        case (_, true): return Self.oneLineFont
        case (_, false): return Self.font
        }
    }

    private func color(for emphasis: RowEmphasis) -> NSColor {
        // Offline colours everything red regardless of which direction is moving.
        if model.state.textIsRed { return .systemRed }
        // A held reading is real but a moment old, so it is dimmed rather than replaced.
        if model.freshness == .holding { return .tertiaryLabelColor }
        switch emphasis {
        case .active: return .labelColor
        case .normal: return .labelColor
        case .muted: return .secondaryLabelColor
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
        setAccessibilityValue(accessibilityValue())
    }

    /// Spoken description of the current readout, also used for the status button itself.
    func accessibilityValue() -> String {
        let unit = model.unit.shortLabel
        if model.freshness == .unavailable {
            return "Live reading unavailable, \(model.state.spokenDescription)"
        }
        if model.layout == .adaptive {
            let isUpload = model.activeDirection == .upload
            let direction = isUpload ? "Uploading" : "Downloading"
            let number = isUpload ? model.upText : model.downText
            return "\(direction) at \(number) \(unit), \(model.state.spokenDescription)"
        }
        let down = "Download \(model.downText)\(model.downEmphasis == .active ? " (downloading)" : "")"
        let up = "upload \(model.upText)\(model.upEmphasis == .active ? " (uploading)" : "")"
        return "\(down), \(up) \(unit), \(model.state.spokenDescription)"
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
}
