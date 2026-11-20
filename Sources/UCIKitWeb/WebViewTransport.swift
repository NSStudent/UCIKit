import Foundation
import UCIKit
import WebKit
#if canImport(UIKit)
import UIKit
public typealias UCIKitHostView = UIView
#else
import AppKit
public typealias UCIKitHostView = NSView
#endif

/// Runs a WebAssembly UCI engine (for example stockfish.js) in a hidden `WKWebView` and talks to it with text.
///
/// The engine runs in WebKit's web-content process, not in this app's process: the app only exchanges UCI
/// lines with it. Pages are served from `127.0.0.1` with cross-origin isolation so multi-threaded builds get
/// `SharedArrayBuffer`; when a page is not isolated the transport loads `fallbackScript` (a single-threaded
/// build) if there is one.
public final class WebViewTransport: UCITransport, @unchecked Sendable {
  /// Where to put the (1×1 pt, transparent) web view. A web view outside any window may be throttled.
  /// Defaults to the key window.
  @MainActor public static var hostView: (@MainActor () -> UCIKitHostView?)? = nil

  public let engineDirectory: URL
  public let script: String
  public let fallbackScript: String?
  public var capabilities: EngineTransportCapabilities { .webView }

  private let lock = NSLock()
  private var sessionID: UUID?
  private var mailbox: UCITransportMailbox?
  private var host: WebEngineHost?
  private var stopped = false
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []
  private let server: LoopbackServer

  /// - Parameters:
  ///   - engineDirectory: folder with the engine's `.js` and `.wasm` files.
  ///   - script: the engine to load, for example `stockfish-19.js` (multi-threaded).
  ///   - fallbackScript: a single-threaded build used when the page cannot get `SharedArrayBuffer`.
  public init(engineDirectory: URL, script: String, fallbackScript: String? = nil) {
    self.engineDirectory = engineDirectory
    self.script = script
    self.fallbackScript = fallbackScript
    server = LoopbackServer(engineDirectory: engineDirectory, bridgePage: WebEngineHost.bridgePage)
  }

  public func start(sessionID: UUID, handler: @escaping @Sendable (UCITransportEvent) async -> Void) throws {
    let file = engineDirectory.appendingPathComponent(script)
    guard FileManager.default.fileExists(atPath: file.path) else { throw EngineError.missingResource(file) }
    try server.start()
    let mailbox = UCITransportMailbox()
    try lock.withLock {
      guard self.sessionID == nil else { throw EngineError.busy }
      self.sessionID = sessionID
      self.mailbox = mailbox
      stopped = false
    }
    mailbox.deliver(to: handler)
    var components = URLComponents(url: server.pageURL, resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "engine", value: script)] + (fallbackScript.map { [URLQueryItem(name: "fallback", value: $0)] } ?? [])
    let url = components.url!
    Task { @MainActor in
      let host = WebEngineHost(url: url, mailbox: mailbox) { [weak self] in self?.finished(sessionID: sessionID) }
      let attached = self.lock.withLock { () -> Bool in
        guard self.sessionID == sessionID else { return false }
        self.host = host
        return true
      }
      if attached { host.load() }
    }
  }

  public func send(_ command: String, sessionID: UUID) throws {
    let active = lock.withLock { self.sessionID == sessionID && !stopped }
    guard active else { throw EngineError.notReady }
    Task { @MainActor in
      let host = self.lock.withLock { self.sessionID == sessionID ? self.host : nil }
      host?.send(command)
    }
  }

  public func requestStop(sessionID: UUID) {
    let active = lock.withLock { self.sessionID == sessionID && !stopped }
    guard active else { return }
    Task { @MainActor in
      let host = self.lock.withLock { self.host }
      if let host { host.shutDown() } else { self.finished(sessionID: sessionID) }
    }
  }

  public func waitUntilStopped(sessionID: UUID, timeout: Duration) async throws {
    let done = lock.withLock { self.sessionID != sessionID || stopped }
    if !done {
      let finished = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
          await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let already = self.lock.withLock { () -> Bool in
              if self.stopped || self.sessionID != sessionID { return true }
              self.stopWaiters.append(continuation)
              return false
            }
            if already { continuation.resume() }
          }
          return true
        }
        group.addTask { try? await Task.sleep(for: timeout); return false }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
      }
      guard finished else { throw EngineError.shutdownTimeout }
    }
    lock.withLock {
      if self.sessionID == sessionID { self.sessionID = nil; host = nil; mailbox = nil }
    }
  }

  private func finished(sessionID: UUID) {
    let (mailbox, waiters): (UCITransportMailbox?, [CheckedContinuation<Void, Never>]) = lock.withLock {
      guard self.sessionID == sessionID, !stopped else { return (nil, []) }
      stopped = true
      let waiters = stopWaiters
      stopWaiters = []
      return (self.mailbox, waiters)
    }
    mailbox?.append(.completed)
    for waiter in waiters { waiter.resume() }
  }
}

/// The web view, its bridge page and the message handler. Main actor only.
@MainActor
final class WebEngineHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  private let url: URL
  private let mailbox: UCITransportMailbox
  private let onFinish: @Sendable () -> Void
  private var webView: WKWebView?
  private var ready = false
  private var pending: [String] = []
  private var finished = false

  init(url: URL, mailbox: UCITransportMailbox, onFinish: @escaping @Sendable () -> Void) {
    self.url = url
    self.mailbox = mailbox
    self.onFinish = onFinish
  }

  func load() {
    let configuration = WKWebViewConfiguration()
    let controller = configuration.userContentController
    controller.add(WeakMessageHandler(self), name: "uci")
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
    webView.navigationDelegate = self
    #if DEBUG
    webView.isInspectable = true
    #endif
    #if canImport(UIKit)
    webView.alpha = 0.01
    webView.isUserInteractionEnabled = false
    webView.accessibilityElementsHidden = true
    #endif
    self.webView = webView
    if let parent = WebViewTransport.hostView?() ?? Self.keyWindowView() {
      parent.addSubview(webView)
    }
    webView.load(URLRequest(url: url))
  }

  func send(_ command: String) {
    guard !finished else { return }
    guard ready, let webView else { pending.append(command); return }
    webView.callAsyncJavaScript("return uciSend(c)", arguments: ["c": command], in: nil, in: .page) { _ in }
  }

  func shutDown() {
    guard !finished else { return }
    webView?.callAsyncJavaScript("return uciKill()", arguments: [:], in: nil, in: .page) { _ in }
    finish()
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "uci")
    webView?.navigationDelegate = nil
    webView?.removeFromSuperview()
    webView = nil
    onFinish()
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any], let kind = body["k"] as? String else { return }
    switch kind {
    case "lines":
      for line in body["v"] as? [String] ?? [] { mailbox.append(.output(line)) }
    case "ready":
      ready = true
      let commands = pending
      pending = []
      for command in commands { send(command) }
    case "error":
      mailbox.append(.failure(.nativeFailure(body["v"] as? String ?? "The web engine failed.")))
      finish()
    default:
      break
    }
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    mailbox.append(.failure(.engineExitedUnexpectedly))
    finish()
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
    mailbox.append(.failure(.nativeFailure(error.localizedDescription)))
    finish()
  }

  private static func keyWindowView() -> UCIKitHostView? {
    #if canImport(UIKit)
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
    #else
    return NSApplication.shared.keyWindow?.contentView
    #endif
  }

  /// The page that hosts the engine in a Web Worker and relays its lines. Part of UCIKit (MIT): it only loads
  /// the engine script by URL.
  nonisolated static let bridgePage = """
  <!doctype html><html><head><meta charset="utf-8"><title>UCIKit</title></head><body><script>
  const post = (o) => window.webkit.messageHandlers.uci.postMessage(o);
  const params = new URLSearchParams(location.search);
  let worker = null, queue = [], timer = null;
  function flush() { timer = null; if (queue.length) { post({ k: 'lines', v: queue }); queue = []; } }
  function boot() {
    const threads = self.crossOriginIsolated === true && typeof SharedArrayBuffer === 'function';
    const script = threads || !params.get('fallback') ? params.get('engine') : params.get('fallback');
    try { worker = new Worker(script); } catch (e) { post({ k: 'error', v: String(e) }); return; }
    worker.onmessage = (e) => {
      const line = String(e.data);
      if (line.includes(' currmove ')) return;
      queue.push(line);
      if (queue.length >= 32 || /^(uciok|readyok|bestmove|id |option )/.test(line)) flush();
      else if (!timer) timer = setTimeout(flush, 25);
    };
    worker.onerror = (e) => post({ k: 'error', v: String(e.message || e) });
    post({ k: 'ready', v: { threads: threads, script: script } });
  }
  window.uciSend = (c) => { if (worker) worker.postMessage(c); return true; };
  window.uciKill = () => { if (worker) { worker.terminate(); worker = null; } return true; };
  boot();
  </script></body></html>
  """
}

/// Breaks the retain cycle between the user content controller and the host.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
  weak var target: WebEngineHost?
  init(_ target: WebEngineHost) { self.target = target }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    MainActor.assumeIsolated { target?.userContentController(userContentController, didReceive: message) }
  }
}
