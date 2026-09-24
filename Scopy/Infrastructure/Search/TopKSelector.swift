import Foundation

/// Keeps the best `capacity` elements offered so far. Internally a min-heap ordered by "worse",
/// so the root is the weakest kept element and a better candidate replaces it in O(log k).
struct TopKSelector<Element> {
    private var heap: [Element] = []
    private let capacity: Int
    private let isBetter: (Element, Element) -> Bool

    init(capacity: Int, isBetter: @escaping (Element, Element) -> Bool) {
        self.capacity = max(0, capacity)
        self.isBetter = isBetter
    }

    var count: Int { heap.count }

    mutating func reserveCapacity(_ n: Int) {
        heap.reserveCapacity(n)
    }

    mutating func offer(_ element: Element) {
        guard capacity > 0 else { return }
        if heap.count < capacity {
            heap.append(element)
            siftUp(from: heap.count - 1)
        } else if isBetter(element, heap[0]) {
            heap[0] = element
            siftDown(from: 0)
        }
    }

    /// The kept elements, best first.
    func sortedElements() -> [Element] {
        heap.sorted(by: isBetter)
    }

    private func isWorse(_ lhs: Element, _ rhs: Element) -> Bool {
        isBetter(rhs, lhs)
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        var parent = (child - 1) / 2
        while child > 0 && isWorse(heap[child], heap[parent]) {
            heap.swapAt(child, parent)
            child = parent
            parent = (child - 1) / 2
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var candidate = parent

            if left < heap.count && isWorse(heap[left], heap[candidate]) {
                candidate = left
            }
            if right < heap.count && isWorse(heap[right], heap[candidate]) {
                candidate = right
            }

            if candidate == parent { return }
            heap.swapAt(parent, candidate)
            parent = candidate
        }
    }
}
