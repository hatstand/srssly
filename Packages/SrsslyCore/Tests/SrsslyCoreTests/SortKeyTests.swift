import Testing
@testable import SrsslyCore

@Suite struct SortKeyTests {
    @Test func betweenEnds() {
        let k = SortKey.between(nil, nil)
        #expect(!k.isEmpty)
        #expect(SortKey.between(nil, k) < k)
        #expect(SortKey.between(k, nil) > k)
    }

    @Test func alwaysFitsBetweenAdjacentKeys() {
        var lo = "a"
        let hi = "b"
        for _ in 0..<50 {
            let mid = SortKey.between(lo, hi)
            #expect(lo < mid && mid < hi)
            #expect(!mid.hasSuffix("0"))
            lo = mid
        }
    }

    @Test func insertsBeforeAKeyThatEndsTight() {
        // "a1" has no room directly below unless we extend "a0…".
        let k = SortKey.between("a", "a1")
        #expect("a" < k && k < "a1")
    }

    @Test func appendingManyStaysOrdered() {
        var keys: [String] = []
        for _ in 0..<200 { keys.append(SortKey.between(keys.last, nil)) }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == 200)
    }

    @Test func bulkKeysAreOrderedAndShort() {
        let keys = SortKey.keys(between: nil, nil, count: 60)
        #expect(keys.count == 60)
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == 60)
        #expect(keys.allSatisfy { $0.count <= 3 })
        let more = SortKey.keys(between: keys[3], keys[4], count: 10)
        #expect(more.allSatisfy { keys[3] < $0 && $0 < keys[4] })
    }
}
