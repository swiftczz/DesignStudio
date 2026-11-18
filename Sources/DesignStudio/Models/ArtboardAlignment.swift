import CoreGraphics

/// 拖动时在世界坐标中对齐，吸附距离由视口缩放换算。
nonisolated enum ArtboardAlignment {
    struct Guide: Equatable {
        let start: CGPoint
        let end: CGPoint
    }

    struct Result: Equatable {
        let frame: CGRect
        let guides: [Guide]
    }

    private struct Match {
        let delta: CGFloat
        let coordinate: CGFloat
        let target: CGRect
        let perpendicularDistance: CGFloat
    }

    static func snap(_ frame: CGRect, to neighbors: [CGRect], tolerance: CGFloat) -> Result {
        let horizontal = closestMatch(for: frame, neighbors: neighbors, axis: .x, tolerance: tolerance)
        let vertical = closestMatch(for: frame, neighbors: neighbors, axis: .y, tolerance: tolerance)
        let aligned = frame.offsetBy(dx: horizontal?.delta ?? 0, dy: vertical?.delta ?? 0)

        var guides: [Guide] = []
        if let horizontal {
            guides.append(Guide(start: CGPoint(x: horizontal.coordinate, y: min(aligned.minY, horizontal.target.minY)),
                                end: CGPoint(x: horizontal.coordinate, y: max(aligned.maxY, horizontal.target.maxY))))
        }
        if let vertical {
            guides.append(Guide(start: CGPoint(x: min(aligned.minX, vertical.target.minX), y: vertical.coordinate),
                                end: CGPoint(x: max(aligned.maxX, vertical.target.maxX), y: vertical.coordinate)))
        }
        return Result(frame: aligned, guides: guides)
    }

    private enum Axis { case x, y }

    private static func closestMatch(for frame: CGRect, neighbors: [CGRect], axis: Axis,
                                     tolerance: CGFloat) -> Match? {
        let anchors = axis == .x ? [frame.minX, frame.midX, frame.maxX] : [frame.minY, frame.midY, frame.maxY]
        var best: Match?
        for target in neighbors {
            let targetAnchors = axis == .x ? [target.minX, target.midX, target.maxX] : [target.minY, target.midY, target.maxY]
            let perpendicularDistance = axis == .x ? abs(frame.midY - target.midY) : abs(frame.midX - target.midX)
            for (index, anchor) in anchors.enumerated() {
                for (targetIndex, coordinate) in targetAnchors.enumerated() where (index == 1) == (targetIndex == 1) {
                    let delta = coordinate - anchor
                    let distance = abs(delta)
                    guard distance <= tolerance else { continue }
                    if let best, distance > abs(best.delta)
                        || (distance == abs(best.delta) && perpendicularDistance >= best.perpendicularDistance) {
                        continue
                    }
                    best = Match(delta: delta, coordinate: coordinate, target: target,
                                 perpendicularDistance: perpendicularDistance)
                }
            }
        }
        return best
    }
}
