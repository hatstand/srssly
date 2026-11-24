import Foundation
import SrsslyCore

public struct FetchedResource: Sendable, Equatable {
    public var data: Data
    public var mimeType: String?
    /// The URL after redirects; relative links in a page resolve against it.
    public var finalURL: URL

    public init(data: Data, mimeType: String? = nil, finalURL: URL) {
        self.data = data
        self.mimeType = mimeType
        self.finalURL = finalURL
    }
}

public enum ResourceFetchError: Error, Equatable, Sendable {
    /// No network the caller allows, e.g. only mobile data when caching is
    /// Wi-Fi only. Stop the whole run rather than failing each article.
    case networkUnavailable
    case http(status: Int)
    case tooLarge
    case transport(String)
}

/// Downloads pages and images for the offline cache.
public protocol ResourceFetching: Sendable {
    func fetch(_ url: URL, allowsCellular: Bool) async throws(ResourceFetchError) -> FetchedResource
}

/// Downloads directly from the sites.
///
/// When cellular isn't allowed, requests are refused on "expensive" networks
/// (mobile data, personal hotspots) and in Low Data Mode, so a run that
/// starts on Wi-Fi stops cleanly when the device leaves it.
public struct HTTPResourceFetcher: ResourceFetching {
    public static let maxBytes = 25 * 1024 * 1024

    private let wifiOnly: URLSession
    private let anyNetwork: URLSession

    public init() {
        let wifi = URLSessionConfiguration.default
        wifi.allowsExpensiveNetworkAccess = false
        wifi.allowsConstrainedNetworkAccess = false
        let any = URLSessionConfiguration.default
        for config in [wifi, any] {
            config.timeoutIntervalForRequest = 30
            config.httpAdditionalHeaders = ["User-Agent": HTTPFeedFetcher.userAgent]
            // The offline cache is our cache; don't keep a second copy.
            config.urlCache = nil
        }
        self.init(wifiOnly: URLSession(configuration: wifi), anyNetwork: URLSession(configuration: any))
    }

    /// For tests: sessions to use for each network policy.
    public init(wifiOnly: URLSession, anyNetwork: URLSession) {
        self.wifiOnly = wifiOnly
        self.anyNetwork = anyNetwork
    }

    public func fetch(_ url: URL, allowsCellular: Bool) async throws(ResourceFetchError) -> FetchedResource {
        let session = allowsCellular ? anyNetwork : wifiOnly
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError {
            if error.networkUnavailableReason != nil || error.code == .notConnectedToInternet || error.code == .dataNotAllowed {
                throw .networkUnavailable
            }
            throw .transport(error.localizedDescription)
        } catch {
            throw .transport(String(describing: error))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw .http(status: http.statusCode)
        }
        guard data.count <= Self.maxBytes else { throw .tooLarge }
        return FetchedResource(data: data, mimeType: response.mimeType, finalURL: response.url ?? url)
    }
}
