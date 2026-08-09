import Foundation
import LoupeCore
import WebKit

// The WebKit delegates: they turn callbacks into `await`, and record the things
// a page can do that the caller would otherwise never learn about.

// MARK: - Navigation

/// Turns `WKNavigationDelegate` callbacks into a single awaitable "the load
/// finished, or here is why it did not".
///
/// The callbacks arrive on the main thread, which is also where this type lives,
/// so the delegate methods are plain main-actor methods. Their completion
/// handlers must be spelled `@MainActor` to match the SDK, see below.
@MainActor
final class NavigationCoordinator: NSObject, WKNavigationDelegate {
    private var waiter: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private weak var webView: WKWebView?

    /// HTTP status of the most recent main-frame response, when there was one.
    /// A 404 is a perfectly successful *navigation*, so this is reported as a note
    /// rather than thrown — but an agent that asked for a page and got an error
    /// page needs to be told.
    private(set) var lastStatusCode: Int?
    /// Incremented on every completed main-frame navigation. Element handles are
    /// stamped with it so a stale handle can be named as stale.
    private(set) var generation = 1
    /// Set when the web content process dies. A crashed process leaves a blank
    /// view that would screenshot as a plain white page, so the driver checks this
    /// before every verb and reloads rather than hand back a convincing lie.
    private(set) var contentProcessDidTerminate = false

    /// Clear the crash flag once the driver has dealt with it.
    func acknowledgeCrash() { contentProcessDidTerminate = false }

    func attach(to webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
    }

    /// Run `start` and wait for the resulting navigation to finish.
    func awaitNavigation(
        timeout: Double, describing what: String, start: () -> Void
    ) async throws {
        guard waiter == nil else {
            throw LoupeError.failed("internal: two navigations were awaited at once")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiter = continuation
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(
                    .failure(
                        LoupeError.timeout(
                            "\(what) did not finish within \(Int(timeout))s — the server may be stalled, or the "
                                + "page may be blocked on a resource that never arrives")))
            }
            start()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation = waiter else { return }
        waiter = nil
        continuation.resume(with: result)
    }

    private func failed(_ error: Error) {
        let nsError = error as NSError
        // -999 (cancelled) is what a superseding navigation looks like: the page
        // redirected via JS while the first load was still in flight. If another
        // load is already running, the *next* didFinish is the answer we want.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled,
            webView?.isLoading == true {
            return
        }
        finish(.failure(LoupeError.failed(describe(nsError))))
    }

    /// Turn URLSession/WebKit error codes into something that tells the caller what
    /// to do next.
    private func describe(_ error: NSError) -> String {
        // Both keys appear in the wild; WebKit populates the URL one.
        let url =
            (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
            ?? (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
            ?? "the page"
        guard error.domain == NSURLErrorDomain else {
            return "could not load \(url): \(error.localizedDescription)"
        }
        let remedy: String
        switch error.code {
            case NSURLErrorCannotFindHost:
                remedy = "DNS has no record for that host — check the spelling, or that the dev server is up"
            case NSURLErrorCannotConnectToHost:
                remedy = "nothing is listening on that host and port"
            case NSURLErrorNotConnectedToInternet:
                remedy = "this machine has no network route"
            case NSURLErrorTimedOut:
                remedy = "the server accepted the connection but never answered"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorServerCertificateNotYetValid:
                remedy =
                    "TLS failed. A self-signed dev certificate is rejected outright here; serve plain http:// "
                    + "on localhost instead, which WebKit allows"
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                remedy =
                    "App Transport Security blocked plain http:// to a non-loopback host; use https://, or "
                    + "point at localhost/127.0.0.1, which is exempt"
            case NSURLErrorCancelled:
                remedy = "the load was cancelled, usually by the page navigating away mid-load"
            case NSURLErrorUnsupportedURL:
                remedy = "that URL scheme cannot be loaded by a web view"
            default:
                remedy = error.localizedDescription
        }
        return "could not load \(url): \(remedy) [\(error.domain) \(error.code)]"
    }

    // MARK: WKNavigationDelegate
    //
    // WebKit declares these protocols `WK_SWIFT_UI_ACTOR`, so the methods — and
    // their completion-handler blocks — are main-actor isolated. The `@MainActor`
    // on each closure type is load-bearing: without it the method merely *nearly*
    // matches the @objc optional requirement. That compiles, never binds, and the
    // driver then hangs waiting for a load that already finished.

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        generation += 1
        finish(.success(()))
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        failed(error)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failed(error)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
            let http = navigationResponse.response as? HTTPURLResponse {
            lastStatusCode = http.statusCode
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        contentProcessDidTerminate = true
        finish(
            .failure(
                LoupeError.failed(
                    "the web content process crashed while loading — the page is gone; call prepare() again")))
    }
}

// MARK: - Dialogs and popups

/// Answers the modal panels a page can put up, so a JS `alert()` cannot wedge the
/// driver, and records them so the caller learns they happened.
@MainActor
final class DialogCoordinator: NSObject, WKUIDelegate {
    /// Dialogs seen since the last drain, newest last.
    private(set) var dialogs: [String] = []

    func drainDialogs() -> [String] {
        defer { dialogs = [] }
        return dialogs
    }

    // As with the navigation delegate, `@MainActor` on each completion handler is
    // what makes these bind at all. If one silently stops binding, a page's
    // `alert()` blocks WebKit forever and every later call times out.

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Returning nil would make target="_blank" links do nothing at all, which
        // looks exactly like a press that failed. Load it in place instead and say
        // so — one web view is the whole point of this driver.
        if let url = navigationAction.request.url {
            dialogs.append("a link opened a new window; loaded \(url.absoluteString) in place instead")
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void
    ) {
        dialogs.append("page called alert(\"\(message)\") — dismissed")
        completionHandler()
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        dialogs.append("page called confirm(\"\(message)\") — answered OK")
        completionHandler(true)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        dialogs.append("page called prompt(\"\(prompt)\") — answered with the default text")
        completionHandler(defaultText)
    }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        dialogs.append("page asked for a file to upload — cancelled (this driver cannot pick files)")
        completionHandler(nil)
    }
}
