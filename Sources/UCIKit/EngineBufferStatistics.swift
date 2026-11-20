/// Lifetime counts of updates evicted from bounded buffers. Each subscriber delivery counts separately.
/// Includes the compatibility streams retained by the legacy stream properties.
/// Counters remain available after shutdown and saturate at UInt64.max.
public struct EngineBufferStatistics: Equatable, Sendable {
  public internal(set) var responses: UInt64 = 0
  public internal(set) var outputs: UInt64 = 0
  public internal(set) var events: UInt64 = 0
  public internal(set) var analysis: UInt64 = 0
  public internal(set) var nativeDiagnostics: UInt64 = 0

  public init() {}

  mutating func record(_ count: Int, channel: EngineBufferChannel) {
    guard count > 0 else { return }
    let amount = UInt64(count)
    switch channel {
    case .responses: responses = Self.add(responses, amount)
    case .outputs: outputs = Self.add(outputs, amount)
    case .events: events = Self.add(events, amount)
    case .analysis: analysis = Self.add(analysis, amount)
    case .nativeDiagnostics: nativeDiagnostics = Self.add(nativeDiagnostics, amount)
    }
  }
  private static func add(_ current: UInt64, _ amount: UInt64) -> UInt64 {
    let (result, overflow) = current.addingReportingOverflow(amount)
    return overflow ? .max : result
  }
}

enum EngineBufferChannel { case responses, outputs, events, analysis, nativeDiagnostics }
