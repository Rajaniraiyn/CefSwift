import Foundation
import Testing

@testable import CCef
@testable import CefKit

// The framework-free parts of CefProfile.data(for:) and bytes(for:): how a
// URLRequest becomes a cef_request_t, and how errors are named.

@Suite struct URLRequestPlanTests {
    private let url = URL(string: "https://example.com/api?q=1")!

    @Test func aPlainRequestIsAGetForItsOwnSite() throws {
        let plan = try URLRequestPlan(URLRequest(url: url), options: .init())
        #expect(plan.url == url)
        #expect(plan.method == "GET")
        #expect(plan.headers.isEmpty)
        #expect(plan.body == nil)
        #expect(plan.referrer == nil)
        #expect(plan.siteForCookies == url)
        #expect(plan.idleTimeout == .seconds(60))
        // Cookies on (httpShouldHandleCookies), no retries on 5xx.
        #expect(plan.flags == Int32(UR_FLAG_ALLOW_STORED_CREDENTIALS.rawValue | UR_FLAG_NO_RETRY_ON_5XX.rawValue))
    }

    @Test func methodHeadersBodyAndReferrer() throws {
        var request = URLRequest(url: url)
        request.httpMethod = "post"
        request.httpBody = Data("a=1".utf8)
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue("yes", forHTTPHeaderField: "X-App")
        request.setValue("https://example.com/from", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 2.5
        let plan = try URLRequestPlan(request, options: .init())
        #expect(plan.method == "POST")
        #expect(plan.body == .bytes(Data("a=1".utf8)))
        #expect(plan.headers == [.init(name: "Content-Type", value: "text/plain"), .init(name: "X-App", value: "yes")])
        #expect(plan.referrer == URL(string: "https://example.com/from"))
        #expect(plan.idleTimeout == .milliseconds(2500))
    }

    @Test func optionsBecomeFlags() throws {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        var options = CefProfile.RequestOptions()
        options.stopsAtRedirects = true
        options.retriesOnServerError = true
        options.uploadProgress = { _ in }
        options.siteForCookies = URL(string: "https://site.example/")
        options.bodyFile = URL(fileURLWithPath: "/tmp/upload.bin")
        request.httpBody = Data("ignored".utf8)
        let plan = try URLRequestPlan(request, options: options)
        #expect(plan.flags == Int32(UR_FLAG_STOP_ON_REDIRECT.rawValue | UR_FLAG_REPORT_UPLOAD_PROGRESS.rawValue))
        #expect(plan.siteForCookies == URL(string: "https://site.example/"))
        #expect(plan.body == .file(URL(fileURLWithPath: "/tmp/upload.bin")))
    }

    @Test(arguments: [
        (URLRequest.CachePolicy.useProtocolCachePolicy, UR_FLAG_NONE.rawValue),
        (.reloadIgnoringLocalCacheData, UR_FLAG_SKIP_CACHE.rawValue),
        (.reloadIgnoringLocalAndRemoteCacheData, UR_FLAG_SKIP_CACHE.rawValue),
        (.returnCacheDataDontLoad, UR_FLAG_ONLY_FROM_CACHE.rawValue),
        (.returnCacheDataElseLoad, UR_FLAG_NONE.rawValue),
        (.reloadRevalidatingCacheData, UR_FLAG_NONE.rawValue),
    ])
    func cachePolicies(policy: URLRequest.CachePolicy, flags: UInt32) {
        #expect(URLRequestPlan.cacheFlags(for: policy) == flags)
    }

    @Test func noTimeoutWhenTheIntervalIsNotPositive() throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 0
        #expect(try URLRequestPlan(request, options: .init()).idleTimeout == nil)
    }

    @Test func aBodyStreamCannotBeSent() {
        var request = URLRequest(url: url)
        request.httpBodyStream = InputStream(data: Data([1, 2, 3]))
        #expect(throws: CefError.self) { try URLRequestPlan(request, options: .init()) }
    }

    @Test func aRelativeURLIsInvalid() {
        let request = URLRequest(url: URL(string: "relative/path")!)
        #expect {
            try URLRequestPlan(request, options: .init())
        } throws: { error in
            (error as? CefLoadError)?.code == -300 && (error as? CefLoadError)?.message.hasPrefix("net::ERR_INVALID_URL") == true
        }
    }
}

@Suite struct URLRequestErrorTests {
    @Test func netErrorsAreNamedAsChromiumNamesThem() {
        let url = URL(string: "http://nowhere.invalid/")!
        #expect(CefLoadError(netError: -105, url: url).message == "net::ERR_NAME_NOT_RESOLVED")
        #expect(CefLoadError(netError: -7, url: url, detail: "slow").message == "net::ERR_TIMED_OUT: slow")
        #expect(CefLoadError(netError: -12345, url: url).message == "net error -12345")
        #expect(CefLoadError(netError: -3, url: url).isCancellation)
    }

    @Test(arguments: [
        (-3, URLError.Code.cancelled),
        (-7, .timedOut),
        (-118, .timedOut),
        (-102, .cannotConnectToHost),
        (-105, .cannotFindHost),
        (-106, .notConnectedToInternet),
        (-101, .networkConnectionLost),
        (-201, .serverCertificateHasBadDate),
        (-202, .serverCertificateHasUnknownRoot),
        (-200, .serverCertificateUntrusted),
        (-300, .badURL),
        (-302, .unsupportedURL),
        (-310, .httpTooManyRedirects),
        (-324, .zeroByteResource),
        (-400, .resourceUnavailable),
        (-2, .unknown),
    ])
    func urlErrorCodes(netError: Int, code: URLError.Code) {
        #expect(CefLoadError.urlErrorCode(forNetError: netError) == code)
    }

    @Test func urlErrorCarriesTheURLAndMessage() {
        let url = URL(string: "http://nowhere.invalid/")!
        let error = CefLoadError(netError: -105, url: url).urlError
        #expect(error.code == .cannotFindHost)
        #expect(error.failingURL == url)
        #expect(error.localizedDescription == "net::ERR_NAME_NOT_RESOLVED")
    }

    @Test func progressFraction() {
        #expect(CefProfile.TransferProgress(completed: 5, total: 10).fractionCompleted == 0.5)
        #expect(CefProfile.TransferProgress(completed: 5, total: nil).fractionCompleted == nil)
        #expect(CefProfile.TransferProgress(completed: 0, total: 0).fractionCompleted == nil)
    }

    @Test func theStreamBufferCountsUnreadBytes() {
        let buffer = URLRequestStreamBuffer()
        #expect(buffer.received(10) == 10)
        #expect(buffer.received(5) == 15)
        buffer.consumed(10)
        #expect(buffer.received(1) == 6)
        #expect(buffer.peak == 15)
    }
}
