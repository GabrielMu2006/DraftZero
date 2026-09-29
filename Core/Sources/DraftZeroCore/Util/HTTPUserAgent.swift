import Foundation

/// 出站请求统一收口：显式设置 User-Agent。
/// 本机（macOS 26.6.2/25G83）CFNetwork 首次构造默认 User-Agent 时会在
/// `initializeUserAgentString` 触发系统崩溃（[NSCFNumber length]）；
/// 请求自带 UA 头后走不到该路径。独立单测不受影响，仅应用进程需要。
public enum HTTPUserAgent {
    public static let value = "DraftZero/0.1 (macOS)"

    /// 给请求盖上显式 User-Agent（不覆盖调用方已设置的值）。
    public static func stamped(_ request: URLRequest) -> URLRequest {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(value, forHTTPHeaderField: "User-Agent")
        }
        return request
    }
}
