protocol EngineClock: Sendable {
  func sleep(for duration: Duration) async throws
}

struct SystemEngineClock: EngineClock {
  func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
