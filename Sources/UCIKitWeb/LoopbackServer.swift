import Darwin
import Foundation

/// A minimal HTTP/1.1 server on 127.0.0.1 (BSD sockets, one thread per connection) for the web view that hosts
/// a WebAssembly engine.
///
/// Every response carries COOP/COEP/CORP: without cross-origin isolation WebKit gives no `SharedArrayBuffer`
/// and multi-threaded engines cannot start. (A `WKURLSchemeHandler` isolates the page but still gives no
/// `SharedArrayBuffer`; `NWListener` did not accept connections inside an iOS app: spike S4, 20 Nov 2026.)
/// Paths live under a random token so other local clients cannot guess them.
final class LoopbackServer: @unchecked Sendable {
  let token = UUID().uuidString.lowercased()
  private let engineDirectory: URL
  private let bridgePage: Data
  private let lock = NSLock()
  private var fd: Int32 = -1
  private(set) var port: UInt16 = 0

  init(engineDirectory: URL, bridgePage: String) {
    self.engineDirectory = engineDirectory.standardizedFileURL
    self.bridgePage = Data(bridgePage.utf8)
  }

  deinit { if fd >= 0 { close(fd) } }

  var pageURL: URL { URL(string: "http://127.0.0.1:\(port)/\(token)/host.html")! }

  func start() throws {
    try lock.withLock {
      guard fd < 0 else { return }
      let socketFD = socket(AF_INET, SOCK_STREAM, 0)
      guard socketFD >= 0 else { throw POSIXError(.EIO) }
      var yes: Int32 = 1
      setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
      var addr = sockaddr_in()
      addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      addr.sin_family = sa_family_t(AF_INET)
      addr.sin_port = 0
      addr.sin_addr.s_addr = inet_addr("127.0.0.1")
      let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
      }
      guard bound == 0, listen(socketFD, 32) == 0 else { close(socketFD); throw POSIXError(.EADDRINUSE) }
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      _ = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
      }
      port = UInt16(bigEndian: addr.sin_port)
      fd = socketFD
      Thread.detachNewThread { [weak self] in
        while true {
          let client = accept(socketFD, nil, nil)
          if client < 0 { if errno == EINTR { continue } else { return } }
          var one: Int32 = 1
          setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
          guard let self else { close(client); return }
          Thread.detachNewThread { self.serve(client) }
        }
      }
    }
  }

  private func serve(_ client: Int32) {
    defer { close(client) }
    var request = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while request.range(of: Data("\r\n\r\n".utf8)) == nil {
      let count = read(client, &buffer, buffer.count)
      if count <= 0 { return }
      request.append(buffer, count: count)
      if request.count > 64 * 1024 { return }
    }
    let head = String(decoding: request, as: UTF8.self)
    let parts = head.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2, parts[0] == "GET" else { return respond(client, status: "405 Method Not Allowed", type: "text/plain", body: Data()) }
    var path = String(parts[1])
    if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<cut]) }
    let prefix = "/\(token)/"
    guard path.hasPrefix(prefix) else { return respond(client, status: "404 Not Found", type: "text/plain", body: Data()) }
    let name = String(path.dropFirst(prefix.count))
    if name == "host.html" { return respond(client, status: "200 OK", type: "text/html; charset=utf-8", body: bridgePage) }
    let file = engineDirectory.appendingPathComponent(name).standardizedFileURL
    guard !name.contains(".."), file.path.hasPrefix(engineDirectory.path + "/"),
          let body = try? Data(contentsOf: file, options: .alwaysMapped) else {
      return respond(client, status: "404 Not Found", type: "text/plain", body: Data())
    }
    let type = switch file.pathExtension {
    case "js", "mjs": "text/javascript"
    case "wasm": "application/wasm"
    case "html": "text/html; charset=utf-8"
    default: "application/octet-stream"
    }
    respond(client, status: "200 OK", type: type, body: body)
  }

  private func respond(_ client: Int32, status: String, type: String, body: Data) {
    let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
      + "Cross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Embedder-Policy: require-corp\r\nCross-Origin-Resource-Policy: same-origin\r\n\r\n"
    sendAll(client, Data(head.utf8))
    sendAll(client, body)
  }

  private func sendAll(_ client: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
      guard var pointer = raw.baseAddress else { return }
      var left = raw.count
      while left > 0 {
        let written = Darwin.write(client, pointer, left)
        if written < 0, errno == EINTR { continue }
        if written <= 0 { return }
        pointer += written
        left -= written
      }
    }
  }
}
