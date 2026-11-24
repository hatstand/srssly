import Foundation
import SrsslyCore

/// Saved pages and images on disk, for reading offline.
///
/// Lives in Application Support (not Caches, which iOS empties when space
/// is low, exactly when someone is about to get on a plane) and is excluded
/// from backups since it can be downloaded again. `OfflineCacher` prunes it.
///
/// Files are named by `OfflineFileName`: resources by their remote URL, so a
/// reader can map any URL in a page to its local copy; pages by article key.
public struct OfflineCache: Sendable {
    public let directory: URL
    public var pagesDirectory: URL { directory.appending(path: "pages", directoryHint: .isDirectory) }
    public var resourcesDirectory: URL { directory.appending(path: "resources", directoryHint: .isDirectory) }

    /// The default location, in Application Support.
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "OfflineCache", directoryHint: .isDirectory)
    }

    public init(directory: URL = OfflineCache.defaultDirectory) throws {
        self.directory = directory
        let fm = FileManager.default
        try fm.createDirectory(at: pagesDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    // MARK: Resources

    /// Where the copy of `remote` is (or would be) kept.
    public func localURL(forResource remote: URL) -> URL {
        resourcesDirectory.appending(path: OfflineFileName.resource(remote), directoryHint: .notDirectory)
    }

    public func hasResource(_ remote: URL) -> Bool {
        FileManager.default.fileExists(atPath: localURL(forResource: remote).path(percentEncoded: false))
    }

    /// Saves a downloaded resource and returns its file name.
    @discardableResult
    public func storeResource(_ data: Data, for remote: URL) throws -> String {
        let url = localURL(forResource: remote)
        try data.write(to: url, options: .atomic)
        return url.lastPathComponent
    }

    // MARK: Pages

    public func localURL(forPageFile name: String) -> URL {
        pagesDirectory.appending(path: name, directoryHint: .notDirectory)
    }

    /// Saves an article's page and returns its file name.
    @discardableResult
    public func storePage(_ data: Data, articleKey: String) throws -> String {
        let name = OfflineFileName.page(articleKey: articleKey)
        try data.write(to: localURL(forPageFile: name), options: .atomic)
        return name
    }

    public func page(named name: String) -> Data? {
        try? Data(contentsOf: localURL(forPageFile: name))
    }

    public func removePage(named name: String) {
        try? FileManager.default.removeItem(at: localURL(forPageFile: name))
    }

    // MARK: Housekeeping

    /// Deletes resource files no article uses any more. Returns bytes freed.
    @discardableResult
    public func removeResources(notIn keep: Set<String>) -> Int {
        var freed = 0
        for (url, size) in files(in: resourcesDirectory) where !keep.contains(url.lastPathComponent) {
            if (try? FileManager.default.removeItem(at: url)) != nil { freed += size }
        }
        return freed
    }

    /// Deletes page files that no article points at. Returns bytes freed.
    @discardableResult
    public func removePages(notIn keep: Set<String>) -> Int {
        var freed = 0
        for (url, size) in files(in: pagesDirectory) where !keep.contains(url.lastPathComponent) {
            if (try? FileManager.default.removeItem(at: url)) != nil { freed += size }
        }
        return freed
    }

    /// Total bytes on disk.
    public func totalBytes() -> Int {
        (files(in: pagesDirectory) + files(in: resourcesDirectory)).reduce(0) { $0 + $1.1 }
    }

    private func files(in directory: URL) -> [(URL, Int)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (url, values.fileSize ?? 0)
        }
    }
}
