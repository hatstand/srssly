import Foundation
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
        var lo = "b"
        let hi = "c"
        for _ in 0..<50 {
            let mid = SortKey.between(lo, hi)
            #expect(lo < mid && mid < hi)
            #expect(!mid.hasSuffix("a"))
            lo = mid
        }
    }

    @Test func insertsBeforeAKeyThatEndsTight() {
        // "bb" has no room directly below unless we extend "ba…".
        let k = SortKey.between("b", "bb")
        #expect("b" < k && k < "bb")
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
        #expect(SortKey.between(nil, nil) == SortKey.middle)
        let more = SortKey.keys(between: keys[3], keys[4], count: 10)
        #expect(more.allSatisfy { keys[3] < $0 && $0 < keys[4] })
    }

    /// SwiftData sorts strings with localized standard comparison by default,
    /// which ignores case and compares digit runs as numbers. Keys must sort
    /// the same way under it as under plain comparison.
    @Test func orderSurvivesLocalizedAndCaseInsensitiveSorts() {
        var keys = SortKey.keys(between: nil, nil, count: 100)
        var (lo, hi) = (keys[40], keys[41])
        for _ in 0..<30 { lo = SortKey.between(lo, hi); keys.append(lo) }
        keys.sort()
        #expect(keys.allSatisfy { $0.allSatisfy { ("a"..."z").contains($0) } })
        #expect(keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } == keys)
        #expect(keys.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending } == keys)
    }
}
