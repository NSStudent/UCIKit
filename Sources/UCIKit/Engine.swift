import Foundation

/// A concurrency-safe owner of one UCI engine, whatever carries its text: an embedded engine in this
/// process, a WebAssembly build in a web view or a separate program.
public final class Engine: Sendable {
  public let descriptor: EngineDescriptor
  public let transportCapabilities: EngineTransportCapabilities
  private let runtime: EngineRuntime

  public init(descriptor: EngineDescriptor, transport: any UCITransport, loggingEnabled: Bool = false) {
    self.descriptor = descriptor
    transportCapabilities = transport.capabilities
    runtime = EngineRuntime(descriptor: descriptor, loggingEnabled: loggingEnabled, transport: transport)
  }

  deinit {
    let runtime = runtime
    Task { await runtime.shutdownForDeinitialization() }
  }

  public var isRunning: Bool { get async { await runtime.isRunning } }
  public var loggingEnabled: Bool { get async { await runtime.loggingEnabled } }
  public var state: EngineState { get async { await runtime.state } }
  public var availableOptions: [EngineResponse.Option] { get async { await runtime.availableOptions } }
  public var bufferStatistics: EngineBufferStatistics { get async { await runtime.bufferStatistics } }

  @available(*, deprecated, message: "Use responses() for an independent bounded subscription.")
  public var responseStream: AsyncStream<EngineResponse>? { get async { await runtime.legacyResponseStream } }
  @available(*, deprecated, message: "Use outputs() for an independent bounded subscription.")
  public var outputStream: AsyncStream<EngineOutput>? { get async { await runtime.legacyOutputStream } }
  @available(*, deprecated, message: "Use events() for an independent bounded subscription.")
  public var eventStream: AsyncStream<EngineEvent>? { get async { await runtime.legacyEventStream } }

  /// Each call creates an independent subscription with at most 256 recent responses.
  /// At most 256 subscriptions are admitted per channel; excess streams finish and emit bufferOverflow.
  public func responses() async -> AsyncStream<EngineResponse> { await runtime.responses() }
  /// Each call creates an independent subscription with at most 256 recent output lines.
  public func outputs() async -> AsyncStream<EngineOutput> { await runtime.outputs() }
  /// Each call creates an independent subscription with at most 256 recent diagnostic events.
  public func events() async -> AsyncStream<EngineEvent> { await runtime.events() }

  /// Launches a handshake; await startAndWaitUntilReady when subsequent work requires readiness.
  public func start(coreCount: Int? = nil, multipv: Int = 1, setupCommands: [EngineCommand]? = nil) async {
    do { try await runtime.start(coreCount: coreCount, multipv: multipv, setupCommands: setupCommands) }
    catch { await runtime.reportOperationError(error) }
  }

  public func startAndWaitUntilReady(coreCount: Int? = nil, multipv: Int = 1,
                                   setupCommands: [EngineCommand]? = nil,
                                   timeout: Duration = .seconds(5)) async throws {
    try await runtime.startAndWaitUntilReady(coreCount: coreCount, multipv: multipv,
                                            setupCommands: setupCommands, timeout: timeout)
  }

  /// Stops in every lifecycle phase and reports any failure through state and events.
  public func stop() async {
    do { try await runtime.stopAndWait(timeout: .seconds(5)) }
    catch { await runtime.reportOperationError(error) }
  }

  /// A timeout keeps native resources reserved until the worker exits.
  public func stopAndWait(timeout: Duration = .seconds(5)) async throws {
    try await runtime.stopAndWait(timeout: timeout)
  }

  /// Requests stop for the active search and awaits its terminal bestmove response.
  public func stopSearchAndWait(timeout: Duration = .seconds(5)) async throws {
    try await runtime.stopSearchAndWait(timeout: timeout)
  }

  public func send(command: EngineCommand) async {
    do { try await runtime.sendChecked(command: command) }
    catch { await runtime.reportOperationError(error) }
  }

  public func sendChecked(command: EngineCommand) async throws { try await runtime.sendChecked(command: command) }

  /// Checks the advertised type, choices and range, then waits for the engine's readiness barrier.
  public func setOption(id: String, value: UCIOptionValue) async throws {
    try await runtime.setOption(id: id, value: value)
  }

  /// Runs one analysis. A concurrent analysis fails with EngineError.busy.
  /// The latest 64 updates are retained. Successful completion appends a final result and closes
  /// production, so later updates cannot evict it. Errors are delivered after buffered updates drain.
  public func analyze(_ request: AnalysisRequest) -> AsyncThrowingStream<AnalysisUpdate, Error> {
    runtime.analysisStream(request)
  }

  @available(*, deprecated, renamed: "set(loggingEnabled:)")
  public func setLoggingEnabled(_ loggingEnabled: Bool) {
    let runtime = runtime
    Task { await runtime.setLoggingEnabled(loggingEnabled) }
  }
  public func set(loggingEnabled: Bool) async { await runtime.setLoggingEnabled(loggingEnabled) }

  /// The caller's commands replace the descriptor's defaults.
  static func initialSetupCommands(descriptor: EngineDescriptor,
                                   setupCommands: [EngineCommand]?) -> [EngineCommand] {
    setupCommands ?? descriptor.setupCommands
  }
}
