import Foundation
import SwiftData

/// Changes read and starred state. `ArticleState` rows only exist for
/// articles someone has touched, so this creates them on demand and never
/// creates one just to record a default. `CloudSync` picks up the save.
public enum ArticleStates {
    /// Sets read and/or starred for the given article keys and saves.
    /// Returns how many articles changed.
    @discardableResult
    public static func set(
        read: Bool? = nil, starred: Bool? = nil, for keys: [String],
        in context: ModelContext, now: Date = .now
    ) throws -> Int {
        guard !keys.isEmpty, read != nil || starred != nil else { return 0 }
        let wanted = Set(keys)
        let existing = Dictionary(
            try context.fetch(FetchDescriptor<ArticleState>(predicate: #Predicate { wanted.contains($0.articleKey) }))
                .map { ($0.articleKey, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        var changed = 0
        for key in wanted {
            if let state = existing[key] {
                var didChange = false
                if let read, state.isRead != read { state.isRead = read; didChange = true }
                if let starred, state.isStarred != starred { state.isStarred = starred; didChange = true }
                if didChange {
                    state.updatedAt = now
                    changed += 1
                }
            } else if read == true || starred == true {
                let state = ArticleState(articleKey: key, isRead: read ?? false, isStarred: starred ?? false)
                state.updatedAt = now
                context.insert(state)
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return changed
    }
}
