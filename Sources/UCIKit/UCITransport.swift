import Foundation

/// What a transport reports back to the runtime: engine output (one or more lines), a failure or the end
/// of the session.
public enum UCITransportEvent: Sendable {
  case output(String)
  case failure(EngineError)
  case completed
  case droppedDiagnostics(Int)
}

/// Carries UCI text between `Engine` and one engine: an embedded engine in this process, a WebAssembly
/// build in a web view, or a separate program.
///
/// Short synchronous enqueue operations allow atomic admission in the runtime actor. Waiting for the
/// engine to stop is separate and runs outside the Swift executor.
public protocol UCITransport: Sendable {
  var capabilities: EngineTransportCapabilities { get }
  /// Starts a session. Events for it go to `handler` in order until `.completed`.
  func start(sessionID: UUID, handler: @escaping @Sendable (UCITransportEvent) async -> Void) throws
  /// Enqueues one command line (without the newline).
  func send(_ command: String, sessionID: UUID) throws
  /// Asks the engine to quit. The session ends with `.completed`.
  func requestStop(sessionID: UUID)
  /// Waits until the session has ended and its resources are released.
  func waitUntilStopped(sessionID: UUID, timeout: Duration) async throws
}

typealias EngineCommandTransport = UCITransport
typealias EngineTransportEvent = UCITransportEvent

/// A bounded, ordered mailbox that transports fill from any thread and drain on one consumer task.
///
/// Up to 256 events wait; when it is full, `info` lines are dropped first (counted and reported as
/// `.droppedDiagnostics`), and if a non-diagnostic line would be lost the mailbox reports
/// `EngineError.bufferOverflow` instead. `.completed` is always delivered last.
public final class UCITransportMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [UCITransportEvent] = []
  private var completionPending = false
  private var overflowed = false
  private var droppedDiagnostics = 0
  private let wakeup: AsyncStream<Void>.Continuation
  private let signals: AsyncStream<Void>
  private var reader: Task<Void, Never>?

  public init() {
    (signals, wakeup) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  /// Starts delivering events to `handler` on one task.
  public func deliver(to handler: @escaping @Sendable (UCITransportEvent) async -> Void) {
    let signals = signals
    let task = Task { [weak self] in
      for await _ in signals {
        guard let self else { return }
        for event in self.drain() {
          guard !Task.isCancelled else { return }
          await handler(event)
        }
      }
    }
    lock.lock(); reader = task; lock.unlock()
  }

  public func append(_ event: UCITransportEvent) {
    lock.lock()
    if case .completed = event {
      completionPending = true
    } else if !overflowed {
      if pending.count == 256 {
        if let index = pending.firstIndex(where: Self.isDiagnostic) {
          pending.remove(at: index)
          droppedDiagnostics = min(droppedDiagnostics, Int.max - 1) + 1
        } else if Self.isDiagnostic(event) {
          droppedDiagnostics = min(droppedDiagnostics, Int.max - 1) + 1
          lock.unlock()
          wakeup.yield(())
          return
        } else {
          pending = [.failure(.bufferOverflow)]
          overflowed = true
        }
      }
      if !overflowed { pending.append(event) }
    }
    lock.unlock()
    wakeup.yield(())
  }

  /// Splits `text` into lines and appends one `.output` per line.
  public func appendLines(_ text: String) {
    for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
      append(.output(String(line)))
    }
  }

  public func finish() {
    wakeup.finish()
    lock.lock(); let task = reader; reader = nil; lock.unlock()
    task?.cancel()
  }

  func drain() -> [UCITransportEvent] {
    lock.lock()
    var result = pending
    pending.removeAll(keepingCapacity: true)
    if droppedDiagnostics > 0 {
      result.append(.droppedDiagnostics(droppedDiagnostics))
      droppedDiagnostics = 0
    }
    if completionPending { result.append(.completed); completionPending = false }
    lock.unlock()
    return result
  }

  private static func isDiagnostic(_ event: UCITransportEvent) -> Bool {
    if case let .output(chunk) = event {
      let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true)
      return !lines.isEmpty && lines.allSatisfy { $0.hasPrefix("info ") }
    }
    return false
  }
}
