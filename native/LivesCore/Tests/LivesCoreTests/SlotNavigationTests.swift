import XCTest
@testable import LivesCore

final class SlotNavigationTests: XCTestCase {
    func testStackedAndSideNeighbours() {
        let stack = TemplateCatalog.definition(for: .stack3)
        XCTAssertEqual(stack.neighbour(of: "middle", toward: .up)?.id, "top")
        XCTAssertEqual(stack.neighbour(of: "middle", toward: .down)?.id, "bottom")
        XCTAssertNil(stack.neighbour(of: "middle", toward: .left))
        XCTAssertNil(stack.neighbour(of: "top", toward: .up))
        let side = TemplateCatalog.definition(for: .side2)
        XCTAssertEqual(side.neighbour(of: "left", toward: .right)?.id, "right")
        XCTAssertNil(side.neighbour(of: "left", toward: .down))
    }

    func testEveryDirectionOnlyReturnsARealAdjacentSlot() {
        for template in TemplateCatalog.all {
            for slot in template.slots {
                for direction in SlotDirection.allCases {
                    guard let neighbour = template.neighbour(of: slot.id, toward: direction) else { continue }
                    XCTAssertNotEqual(neighbour.id, slot.id)
                    switch direction {
                    case .up: XCTAssertEqual(neighbour.y + neighbour.height, slot.y, accuracy: 0.00001)
                    case .down: XCTAssertEqual(slot.y + slot.height, neighbour.y, accuracy: 0.00001)
                    case .left: XCTAssertEqual(neighbour.x + neighbour.width, slot.x, accuracy: 0.00001)
                    case .right: XCTAssertEqual(slot.x + slot.width, neighbour.x, accuracy: 0.00001)
                    }
                }
            }
        }
    }
}
