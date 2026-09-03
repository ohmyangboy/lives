import Foundation

public enum SlotDirection: String, CaseIterable, Sendable {
    case up, down, left, right
}

public extension TemplateDefinition {
    /// Only shared-edge neighbours qualify; ties in asymmetric templates use
    /// the closest centre, then catalogue order for predictable behaviour.
    func neighbour(of slotID: String, toward direction: SlotDirection) -> TemplateSlot? {
        guard let source = slots.first(where: { $0.id == slotID }) else { return nil }
        let epsilon = 0.00001
        let candidates = slots.filter { other in
            guard other.id != slotID else { return false }
            let overlapX = min(source.x + source.width, other.x + other.width) - max(source.x, other.x)
            let overlapY = min(source.y + source.height, other.y + other.height) - max(source.y, other.y)
            switch direction {
            case .up: return abs(other.y + other.height - source.y) < epsilon && overlapX > epsilon
            case .down: return abs(source.y + source.height - other.y) < epsilon && overlapX > epsilon
            case .left: return abs(other.x + other.width - source.x) < epsilon && overlapY > epsilon
            case .right: return abs(source.x + source.width - other.x) < epsilon && overlapY > epsilon
            }
        }
        func distance(_ slot: TemplateSlot) -> Double {
            pow(slot.x + slot.width / 2 - source.x - source.width / 2, 2) +
            pow(slot.y + slot.height / 2 - source.y - source.height / 2, 2)
        }
        return candidates.enumerated().min {
            let a = distance($0.element), b = distance($1.element)
            return abs(a - b) < epsilon ? $0.offset < $1.offset : a < b
        }?.element
    }
}
