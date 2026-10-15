import UIKit

/// Pure geometry so rotating, docking and dragging a floating keyboard never
/// makes the native text document disappear behind it.
enum KeyboardDraftLayout {
    static func frame(in bounds: CGRect, safeArea: UIEdgeInsets, keyboard: CGRect?) -> CGRect {
        let left = max(8, safeArea.left)
        let right = max(8, safeArea.right)
        let top = bounds.minY + max(8, safeArea.top)
        let bottom = bounds.maxY - max(8, safeArea.bottom)
        let width = max(0, min(bounds.width - left - right, 900))
        let x = bounds.minX + left + max(0, (bounds.width - left - right - width) / 2)
        let desiredHeight: CGFloat = 106
        var bandTop = top
        var bandBottom = max(top, bottom)
        if let keyboard {
            let overlap = bounds.intersection(keyboard)
            if !overlap.isNull, overlap.height > 0 {
                let above = max(0, overlap.minY - 6 - top)
                let below = max(0, bottom - overlap.maxY - 6)
                // A floating keyboard near the top must not force a 60-point
                // editor into a 20-point gap. Prefer any full-height free band.
                if below >= desiredHeight {
                    bandTop = overlap.maxY + 6
                } else if above >= desiredHeight || above >= below {
                    bandBottom = max(top, overlap.minY - 6)
                } else {
                    bandTop = min(bottom, overlap.maxY + 6)
                }
            }
        }
        let height = min(desiredHeight, max(0, bandBottom - bandTop))
        return CGRect(x: x, y: bandBottom - height, width: width, height: height)
    }
}
