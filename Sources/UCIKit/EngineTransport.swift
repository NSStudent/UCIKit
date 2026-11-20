//
//  EngineTransport.swift
//  UCIKit
//

/// How a transport carries UCI text to its engine.
public enum EngineTransportMode: Equatable, Sendable {
  /// An engine compiled into this process, with its standard streams redirected to memory buffers.
  case embedded
  /// A WebAssembly build running in a web view (another process, owned by WebKit).
  case webView
  /// A separate program started by this app and spoken to over pipes.
  case externalProcess
}

/// Public capabilities of the selected engine transport.
public struct EngineTransportCapabilities: Equatable, Sendable {
  public var mode: EngineTransportMode
  /// Whether several engines of this transport can run at the same time.
  public var supportsConcurrentInstances: Bool

  public init(mode: EngineTransportMode, supportsConcurrentInstances: Bool) {
    self.mode = mode
    self.supportsConcurrentInstances = supportsConcurrentInstances
  }

  /// One embedded engine per process: its global streams cannot be shared.
  public static let embedded = EngineTransportCapabilities(mode: .embedded, supportsConcurrentInstances: false)
  public static let webView = EngineTransportCapabilities(mode: .webView, supportsConcurrentInstances: true)
  public static let externalProcess = EngineTransportCapabilities(mode: .externalProcess, supportsConcurrentInstances: true)
}
