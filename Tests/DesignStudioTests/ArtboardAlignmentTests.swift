import CoreGraphics
import Testing
@testable import DesignStudio

struct ArtboardAlignmentTests {
    @Test func snapsToEdgesOnBothAxes() {
        let moving = CGRect(x: 102, y: 38, width: 60, height: 40)
        let neighbor = CGRect(x: 20, y: 40, width: 80, height: 75)

        let result = ArtboardAlignment.snap(moving, to: [neighbor], tolerance: 5)

        #expect(result.frame.origin == CGPoint(x: 100, y: 40))
        #expect(result.guides == [
            .init(start: CGPoint(x: 100, y: 40), end: CGPoint(x: 100, y: 115)),
            .init(start: CGPoint(x: 20, y: 40), end: CGPoint(x: 160, y: 40))
        ])
    }

    @Test func snapsCentersOnlyWithinScreenTolerance() {
        let moving = CGRect(x: 82, y: 400, width: 60, height: 40)
        let neighbor = CGRect(x: 0, y: 40, width: 200, height: 75)

        let zoomedOut = ArtboardAlignment.snap(moving, to: [neighbor], tolerance: 5 / 0.33)
        #expect(zoomedOut.frame.origin == CGPoint(x: 70, y: 400))
        #expect(zoomedOut.guides.count == 1)

        let zoomedIn = ArtboardAlignment.snap(moving, to: [neighbor], tolerance: 5)
        #expect(zoomedIn.frame == moving)
        #expect(zoomedIn.guides.isEmpty)
    }
}
