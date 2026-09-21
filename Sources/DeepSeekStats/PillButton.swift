import AppKit

/// A layer-backed pill button.
///
/// The stock `.rounded` bezel paints its own rounded background on top of the
/// view's layer, so pairing it with a `layer.backgroundColor` shows two offset
/// outlines. The bezel is therefore disabled and press feedback is reproduced
/// by dimming the button while it is highlighted.
final class PillButton: NSButton {
    override var isHighlighted: Bool {
        didSet { alphaValue = isHighlighted ? 0.75 : 1 }
    }
}
