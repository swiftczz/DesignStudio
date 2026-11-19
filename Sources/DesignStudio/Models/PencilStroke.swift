import Foundation
import CoreGraphics

nonisolated struct PencilStroke: Equatable {
    enum Weight: Double, CaseIterable, Identifiable {
        case thin = 1, regular = 2, thick = 4, heavy = 8
        var id: Double { rawValue }

        var title: String {
            switch self {
            case .thin: "极细"
            case .regular: "细"
            case .thick: "粗"
            case .heavy: "加粗"
            }
        }
    }

    enum Pattern: String, CaseIterable, Identifiable {
        case solid, dashed, dotted
        var id: String { rawValue }

        var title: String {
            switch self {
            case .solid: "实线"
            case .dashed: "虚线"
            case .dotted: "点线"
            }
        }

        func dash(for width: CGFloat) -> [CGFloat] {
            switch self {
            case .solid: []
            case .dashed: [width * 3, width * 2]
            case .dotted: [width * 0.1, width * 2]
            }
        }
    }

    static let color = "#1F2328"
    var weight = Weight.regular
    var pattern = Pattern.solid

    var width: CGFloat { weight.rawValue }
    var dash: [CGFloat] { pattern.dash(for: width) }

    /// 点使用画板的 CSS 坐标，SVG 的盒子包含圆形端点。
    func element(for points: [CGPoint]) -> (html: String, origin: CGPoint)? {
        guard let first = points.first, points.dropFirst().contains(where: { $0 != first }) else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        let pad = width / 2 + 1
        let origin = CGPoint(x: floor(minX - pad), y: floor(minY - pad))
        let w = Int(ceil(maxX + pad - origin.x))
        let h = Int(ceil(maxY + pad - origin.y))
        func format(_ value: CGFloat) -> String {
            String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
        }
        let coordinates = points.enumerated().map { i, p in
            "\(i == 0 ? "M" : "L")\(format(p.x - origin.x)) \(format(p.y - origin.y))"
        }.joined(separator: " ")
        let dashAttribute = dash.isEmpty ? "" : " stroke-dasharray=\"\(dash.map(format).joined(separator: " "))\""
        let html = """
            <svg data-name="铅笔线条" data-pencil-stroke="" width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)" style="display:block">
            <path d="\(coordinates)" fill="none" stroke="\(Self.color)" stroke-width="\(format(width))" stroke-linecap="round" stroke-linejoin="round"\(dashAttribute) style="pointer-events:none"></path></svg>
            """
        return (html, origin)
    }
}
