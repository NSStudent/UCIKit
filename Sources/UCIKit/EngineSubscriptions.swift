import Foundation

/// Actor-owned subscribers. Cancelling one subscription removes only that subscriber.
struct EngineSubscriptions<Element: Sendable>: Sendable {
  private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

  mutating func subscribe(onTermination: @escaping @Sendable (UUID) -> Void) throws -> AsyncStream<Element> {
    guard continuations.count < 256 else { throw EngineError.bufferOverflow }
    let id = UUID()
    let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(256))
    continuation.onTermination = { @Sendable _ in onTermination(id) }
    continuations[id] = continuation
    return stream
  }

  @discardableResult mutating func publish(_ element: Element) -> Int {
    var dropped = 0
    for (id, continuation) in continuations {
      switch continuation.yield(element) {
      case .terminated: continuations.removeValue(forKey: id)
      case .dropped: dropped += 1
      default: break
      }
    }
    return dropped
  }
  mutating func remove(_ id: UUID) { continuations.removeValue(forKey: id) }
  mutating func finish() {
    let values = Array(continuations.values)
    continuations.removeAll()
    for continuation in values { continuation.finish() }
  }
}
