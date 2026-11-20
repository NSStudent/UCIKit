//
//  EngineEvent.swift
//  UCIKit
//

/// Log severity for ``EngineEvent/log(level:message:)``.
public enum EngineLogLevel: Equatable, Sendable {
  case debug
  case info
  case warning
  case error
}

/// Structured diagnostic events emitted by an ``Engine``.
public enum EngineEvent: Equatable, Sendable {
  case stateChanged(EngineState)
  case commandSent(String)
  case rawResponseReceived(String)
  case responseParsed(EngineResponse)
  case responseIgnored(String)
  case log(level: EngineLogLevel, message: String)
  case failure(EngineError)
}

/// Configuration a client can use when rendering or forwarding engine logs.
public struct EngineLogConfiguration: Equatable, Sendable {
  public var minimumLevel: EngineLogLevel
  public var includesRawResponses: Bool
  public var includesCommands: Bool

  public init(
    minimumLevel: EngineLogLevel = .debug,
    includesRawResponses: Bool = true,
    includesCommands: Bool = true
  ) {
    self.minimumLevel = minimumLevel
    self.includesRawResponses = includesRawResponses
    self.includesCommands = includesCommands
  }
}
