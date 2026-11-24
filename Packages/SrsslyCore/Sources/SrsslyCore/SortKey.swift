/// Fractional sort keys: strings that sort in list order and can always fit
/// a new key between two others, so reordering never renumbers neighbours.
/// Two devices reordering at the same time insert rather than overwrite.
///
/// Keys use the digits `0-9A-Za-z` (base 62, which is also ASCII order),
/// never end in `0`, and compare with plain string comparison. Based on
/// David Greenspan's fractional indexing.
public enum SortKey {
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private static let values: [Character: Int] = Dictionary(uniqueKeysWithValues: digits.enumerated().map { ($1, $0) })
    static var base: Int { digits.count }

    /// A key strictly between `a` and `b` (nil means the start or end of the
    /// list). Precondition: `a < b` when both are given.
    public static func between(_ a: String?, _ b: String?) -> String {
        let lo = (a ?? "").map { values[$0] ?? 0 }
        let hi = b.map { $0.map { values[$0] ?? 0 } }
        if let hi { precondition(compare(lo, hi) < 0, "SortKey.between: \(a ?? "nil") must sort before \(b ?? "nil")") }
        return String(midpoint(lo, hi).map { digits[$0] })
    }

    /// `count` keys in order, strictly between `a` and `b`, spread evenly so
    /// they stay short.
    public static func keys(between a: String?, _ b: String?, count: Int) -> [String] {
        guard count > 0 else { return [] }
        if count == 1 { return [between(a, b)] }
        let mid = between(a, b)
        let left = (count - 1) / 2
        return keys(between: a, mid, count: left) + [mid] + keys(between: mid, b, count: count - 1 - left)
    }

    private static func midpoint(_ a: [Int], _ b: [Int]?) -> [Int] {
        if let b {
            // Share the common prefix (a is padded with zeros).
            var n = 0
            while n < b.count, (n < a.count ? a[n] : 0) == b[n] { n += 1 }
            if n > 0 {
                return Array(b[..<n]) + midpoint(Array(a.dropFirst(n)), Array(b.dropFirst(n)))
            }
        }
        let digitA = a.first ?? 0
        let digitB = b?.first ?? base
        if digitB - digitA > 1 {
            return [(digitA + digitB + 1) / 2]
        }
        if let b, b.count > 1 {
            // b's first digit alone is between a and b.
            return [b[0]]
        }
        return [digitA] + midpoint(Array(a.dropFirst()), nil)
    }

    private static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
