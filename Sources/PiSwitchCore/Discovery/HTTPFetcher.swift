import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DiscoveryError: LocalizedError, Equatable {
    case unsupportedAPI
    case nonLiteralKey
    case invalidBaseURL
    case network(String)
    case http(Int)
    case redirect(Int)
    case tooLarge
    case badFormat(String)
    case pagination(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAPI: return "该 API 类型不支持自动发现，请手动添加。"
        case .nonLiteralKey: return "发现功能需要字面量 Key（当前 Key 是命令或环境变量引用）。"
        case .invalidBaseURL: return "地址为空或不是有效的 http/https URL。"
        case .network(let reason): return "网络错误：\(reason)"
        case .http(let status): return "接口返回 HTTP \(status)。"
        case .redirect(let status): return "接口返回重定向 HTTP \(status)，为保护 Key 不跟随重定向。"
        case .tooLarge: return "响应超过 10 MB 上限。"
        case .badFormat(let reason): return "响应格式不符：\(reason)"
        case .pagination(let reason): return "翻页异常：\(reason)"
        }
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public final class HTTPFetcher: @unchecked Sendable {
    public static let maxBytes = 10 * 1024 * 1024
    public static let timeout: TimeInterval = 30

    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Error messages never include response bodies or request headers.
    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DiscoveryError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw DiscoveryError.network("无效的响应") }
        switch http.statusCode {
        case 200..<300: break
        case 300..<400: throw DiscoveryError.redirect(http.statusCode)
        default: throw DiscoveryError.http(http.statusCode)
        }
        guard data.count <= Self.maxBytes else { throw DiscoveryError.tooLarge }
        return data
    }
}
