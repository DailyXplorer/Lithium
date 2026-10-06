import Foundation

/// A web page's zoom (`WKWebView.pageZoom`), in the steps of View › Zoom In and Zoom Out.
enum PageZoom {
    static let range = 0.5...3.0
    static let step = 0.1

    /// Rounded to whole percents, so steps up and back down land on 100 % exactly.
    static func stepped(_ zoom: Double, by delta: Double) -> Double {
        min(max(((zoom + delta) * 100).rounded() / 100, range.lowerBound), range.upperBound)
    }

    /// "110%", or nil at actual size, where the address bar shows nothing.
    static func label(_ zoom: Double) -> String? {
        let percent = Int((zoom * 100).rounded())
        return percent == 100 ? nil : "\(percent)%"
    }
}
