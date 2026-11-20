import Foundation
import UCIKit

#if os(macOS) || targetEnvironment(macCatalyst)
import Darwin

/// Runs a UCI engine as a separate program and talks to it over pipes.
///
/// Uses `posix_spawn` because `Process` is unavailable in Mac Catalyst. In a sandboxed app the child
/// inherits the app's sandbox; the caller keeps the executable's security-scoped access open while the
/// engine runs (`securityScopedURLs`).
public final class ProcessTransport: UCITransport, @unchecked Sendable {
  public let executable: URL
  public let arguments: [String]
  public let workingDirectory: URL?
  public var capabilities: EngineTransportCapabilities { .externalProcess }

  private let securityScopedURLs: [URL]
  private let lock = NSLock()
  private var sessionID: UUID?
  private var pid: pid_t = 0
  private var stdinFD: Int32 = -1
  private var mailbox: UCITransportMailbox?
  private var exited = false
  private var exitWaiters: [CheckedContinuation<Void, Never>] = []
  private var accessedURLs: [URL] = []

  public init(executable: URL, arguments: [String] = [], workingDirectory: URL? = nil, securityScopedURLs: [URL] = []) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.securityScopedURLs = securityScopedURLs
  }

  deinit {
    if pid > 0, !exited { kill(pid, SIGKILL) }
    if stdinFD >= 0 { close(stdinFD) }
    for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
  }

  public func start(sessionID: UUID, handler: @escaping @Sendable (UCITransportEvent) async -> Void) throws {
    lock.lock()
    defer { lock.unlock() }
    guard self.sessionID == nil else { throw EngineError.busy }
    accessedURLs = securityScopedURLs.filter { $0.startAccessingSecurityScopedResource() }

    var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
    guard pipe(&input) == 0 else { throw EngineError.systemCall(operation: "pipe", code: errno) }
    guard pipe(&output) == 0 else {
      close(input[0]); close(input[1])
      throw EngineError.systemCall(operation: "pipe", code: errno)
    }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, output[1], STDERR_FILENO)
    for fd in [input[0], input[1], output[0], output[1]] { posix_spawn_file_actions_addclose(&actions, fd) }
    if let workingDirectory {
      posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)
    }

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Its own process group, so a stop can signal helper processes too.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attributes, 0)

    let path = executable.path
    let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
    defer { for pointer in argv { free(pointer) } }
    var child: pid_t = 0
    let status = posix_spawn(&child, path, &actions, &attributes, argv, environ)
    close(input[0]); close(output[1])
    guard status == 0 else {
      close(input[1]); close(output[0])
      for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
      accessedURLs = []
      throw EngineError.systemCall(operation: "posix_spawn", code: status)
    }

    let mailbox = UCITransportMailbox()
    mailbox.deliver(to: handler)
    self.mailbox = mailbox
    self.sessionID = sessionID
    pid = child
    stdinFD = input[1]
    exited = false
    var one: Int32 = 1
    setsockopt(stdinFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    signal(SIGPIPE, SIG_IGN)

    let readFD = output[0]
    Thread.detachNewThread { [weak self] in self?.readLoop(fd: readFD, pid: child, mailbox: mailbox) }
  }

  public func send(_ command: String, sessionID: UUID) throws {
    lock.lock()
    defer { lock.unlock() }
    guard self.sessionID == sessionID, stdinFD >= 0, !exited else { throw EngineError.notReady }
    let data = Array((command + "\n").utf8)
    let total = data.count
    let fd = stdinFD
    var offset = 0
    while offset < total {
      let written = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, total - offset) }
      if written < 0 {
        if errno == EINTR { continue }
        throw EngineError.engineExitedUnexpectedly
      }
      offset += written
    }
  }

  public func requestStop(sessionID: UUID) {
    lock.lock()
    guard self.sessionID == sessionID, pid > 0, !exited else { lock.unlock(); return }
    let child = pid
    if stdinFD >= 0 {
      _ = "quit\n".withCString { write(stdinFD, $0, 5) }
      close(stdinFD)
      stdinFD = -1
    }
    lock.unlock()
    // A polite quit first; a program that ignores it is ended.
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
      guard let self else { return }
      self.lock.lock(); let alive = self.pid == child && !self.exited; self.lock.unlock()
      if alive { killpg(child, SIGTERM); kill(child, SIGTERM) }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
        self.lock.lock(); let still = self.pid == child && !self.exited; self.lock.unlock()
        if still { killpg(child, SIGKILL); kill(child, SIGKILL) }
      }
    }
  }

  public func waitUntilStopped(sessionID: UUID, timeout: Duration) async throws {
    enum Status { case other, done, running }
    let status: Status = lock.withLock {
      guard self.sessionID == sessionID else { return .other }
      if exited { finishSessionLocked(); return .done }
      return .running
    }
    guard status == .running else { return }
    let finished = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          let alreadyExited = self.lock.withLock {
            if self.exited { return true }
            self.exitWaiters.append(continuation)
            return false
          }
          if alreadyExited { continuation.resume() }
        }
        return true
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
    guard finished else { throw EngineError.shutdownTimeout }
    lock.withLock { finishSessionLocked() }
  }

  // MARK: - Private

  private func readLoop(fd: Int32, pid child: pid_t, mailbox: UCITransportMailbox) {
    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      if count <= 0 { break }
      pending.append(buffer, count: count)
      while let newline = pending.firstIndex(of: 0x0A) {
        var line = pending[pending.startIndex..<newline]
        if line.last == 0x0D { line = line.dropLast() }
        pending.removeSubrange(pending.startIndex...newline)
        if !line.isEmpty { mailbox.append(.output(String(decoding: line, as: UTF8.self))) }
      }
    }
    if !pending.isEmpty { mailbox.append(.output(String(decoding: pending, as: UTF8.self))) }
    close(fd)
    var status: Int32 = 0
    while waitpid(child, &status, 0) < 0, errno == EINTR {}

    lock.lock()
    let wasStopping = stdinFD < 0
    exited = true
    if stdinFD >= 0 { close(stdinFD); stdinFD = -1 }
    let waiters = exitWaiters
    exitWaiters = []
    lock.unlock()

    if !wasStopping { mailbox.append(.failure(.engineExitedUnexpectedly)) }
    mailbox.append(.completed)
    for waiter in waiters { waiter.resume() }
  }

  /// Called with the lock held once the program has exited.
  private func finishSessionLocked() {
    sessionID = nil
    pid = 0
    mailbox = nil
    for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
    accessedURLs = []
  }
}

/// What a quick `uci` handshake learnt about a program: its name, author and options.
public struct UCIProbeResult: Equatable, Sendable {
  public var name: String?
  public var author: String?
  public var options: [EngineResponse.Option]
  public var startDuration: Duration
}

public enum UCIProbe {
  /// Starts the program, sends `uci` and `isready`, collects `id` and `option` lines and quits.
  /// Throws when it does not start, does not answer `uciok`/`readyok` within `timeout`, or exits.
  public static func run(_ transport: ProcessTransport, timeout: Duration = .seconds(5)) async throws -> UCIProbeResult {
    let session = UUID()
    let clock = ContinuousClock()
    let started = clock.now
    let collector = LineCollector()
    try transport.start(sessionID: session) { event in await collector.receive(event) }
    try transport.send("uci", sessionID: session)
    let gotUCI = await collector.wait(for: "uciok", timeout: timeout)
    if gotUCI { try? transport.send("isready", sessionID: session) }
    let gotReady = gotUCI ? await collector.wait(for: "readyok", timeout: timeout) : false
    let lines = await collector.lines
    transport.requestStop(sessionID: session)
    try? await transport.waitUntilStopped(sessionID: session, timeout: .seconds(5))
    guard gotUCI else { throw await collector.exited ? EngineError.engineExitedUnexpectedly : EngineError.startTimeout }
    guard gotReady else { throw EngineError.startTimeout }
    var result = UCIProbeResult(name: nil, author: nil, options: [], startDuration: clock.now - started)
    for line in lines {
      if line.hasPrefix("id name ") { result.name = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
      else if line.hasPrefix("id author ") { result.author = String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces) }
      else if case let .option(option)? = EngineResponse(rawValue: line) { result.options.append(option) }
    }
    return result
  }
}

private actor LineCollector {
  var lines: [String] = []
  var exited = false
  private var waiters: [(String, CheckedContinuation<Bool, Never>)] = []

  func receive(_ event: UCITransportEvent) {
    switch event {
    case let .output(text):
      for line in text.split(whereSeparator: \.isNewline) {
        let line = String(line)
        lines.append(line)
        waiters.removeAll { prefix, continuation in
          guard line.hasPrefix(prefix) else { return false }
          continuation.resume(returning: true)
          return true
        }
      }
    case .completed, .failure:
      exited = true
      for (_, continuation) in waiters { continuation.resume(returning: false) }
      waiters = []
    case .droppedDiagnostics: break
    }
  }

  func wait(for prefix: String, timeout: Duration) async -> Bool {
    if lines.contains(where: { $0.hasPrefix(prefix) }) { return true }
    if exited { return false }
    return await withCheckedContinuation { continuation in
      waiters.append((prefix, continuation))
      Task {
        try? await Task.sleep(for: timeout)
        self.expire(prefix: prefix)
      }
    }
  }

  private func expire(prefix: String) {
    if let index = waiters.firstIndex(where: { $0.0 == prefix }) {
      waiters.remove(at: index).1.resume(returning: false)
    }
  }
}
#endif
