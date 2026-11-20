import Foundation
import os.log

/// Owns all protocol state. Admission, state transitions, and native enqueueing never suspend.
/// Only readiness/drain/join waits suspend, and every resumed operation rechecks its session ID.
actor EngineRuntime {
  private struct Configuration: Equatable, Sendable {
    var coreCount: Int
    var multipv: Int
    var commands: [EngineCommand]
  }
  private enum Handshake: Equatable { case uci, ready }
  private enum ReadinessAcknowledgement { case query, barrier }
  private struct Waiter {
    let continuation: CheckedContinuation<Void, Error>
    let timer: Task<Void, Never>
    let owner: UUID?
  }
  private struct Search {
    let id: UUID
    var continuation: AsyncThrowingStream<AnalysisUpdate, Error>.Continuation?
    var includeWDL: Bool
    var pondering: Bool
    var stopRequested = false
  }

  private let descriptor: EngineDescriptor
  private let transport: any UCITransport
  private let clock: any EngineClock
  private let logger = Logger(subsystem: "dev.nsstudent.ucikit", category: "Engine")
  private(set) var state: EngineState = .idle
  private(set) var loggingEnabled: Bool
  private(set) var bufferStatistics = EngineBufferStatistics()
  private var lastOverflowDiagnostic: ContinuousClock.Instant?
  var isRunning: Bool { state == .ready || state == .thinking }
  var availableOptions: [EngineResponse.Option] { options.values.sorted { $0.name < $1.name } }
  // Internal observation used to synchronize cancellation tests without relying on task scheduling.
  var readinessWaiterCount: Int { readyWaiters.count }
  var shutdownWaiterCount: Int { shutdownWaiters.count }

  private var sessionID: UUID?
  private var configuration: Configuration?
  private var handshake: Handshake?
  private var readinessAcknowledgements: [ReadinessAcknowledgement] = []
  private var options: [String: EngineResponse.Option] = [:]
  private var readyWaiters: [UUID: Waiter] = [:]
  private var searchWaiters: [UUID: Waiter] = [:]
  private var shutdownWaiters: [UUID: Waiter] = [:]
  private var backgroundStartupTimer: Task<Void, Never>?
  private var keepsStartingWithoutWaiters = false
  private var configurationOperationID: UUID?
  private var shutdownTask: Task<Void, Error>?
  private var terminalFailure: EngineError?
  private var search: Search?
  private var analysisReservation: UUID?
  private var responseSubscriptions = EngineSubscriptions<EngineResponse>()
  private var outputSubscriptions = EngineSubscriptions<EngineOutput>()
  private var eventSubscriptions = EngineSubscriptions<EngineEvent>()
  private(set) var legacyResponseStream: AsyncStream<EngineResponse>?
  private(set) var legacyOutputStream: AsyncStream<EngineOutput>?
  private(set) var legacyEventStream: AsyncStream<EngineEvent>?
  private var legacyResponseContinuation: AsyncStream<EngineResponse>.Continuation?
  private var legacyOutputContinuation: AsyncStream<EngineOutput>.Continuation?
  private var legacyEventContinuation: AsyncStream<EngineEvent>.Continuation?

  init(descriptor: EngineDescriptor, loggingEnabled: Bool,
       transport: any UCITransport, clock: any EngineClock = SystemEngineClock()) {
    self.descriptor = descriptor
    self.loggingEnabled = loggingEnabled
    self.transport = transport
    self.clock = clock
    let response = AsyncStream<EngineResponse>.makeStream(bufferingPolicy: .bufferingNewest(256))
    legacyResponseStream = response.stream; legacyResponseContinuation = response.continuation
    let output = AsyncStream<EngineOutput>.makeStream(bufferingPolicy: .bufferingNewest(256))
    legacyOutputStream = output.stream; legacyOutputContinuation = output.continuation
    let event = AsyncStream<EngineEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
    legacyEventStream = event.stream; legacyEventContinuation = event.continuation
  }

  func responses() -> AsyncStream<EngineResponse> {
    do { return try responseSubscriptions.subscribe { [weak self] id in Task { await self?.removeResponseSubscriber(id) } } }
    catch { emit(.failure(.bufferOverflow)); return AsyncStream { $0.finish() } }
  }
  func outputs() -> AsyncStream<EngineOutput> {
    do { return try outputSubscriptions.subscribe { [weak self] id in Task { await self?.removeOutputSubscriber(id) } } }
    catch { emit(.failure(.bufferOverflow)); return AsyncStream { $0.finish() } }
  }
  func events() -> AsyncStream<EngineEvent> {
    do { return try eventSubscriptions.subscribe { [weak self] id in Task { await self?.removeEventSubscriber(id) } } }
    catch { emit(.failure(.bufferOverflow)); return AsyncStream { $0.finish() } }
  }
  private func removeResponseSubscriber(_ id: UUID) { responseSubscriptions.remove(id) }
  private func removeOutputSubscriber(_ id: UUID) { outputSubscriptions.remove(id) }
  private func removeEventSubscriber(_ id: UUID) { eventSubscriptions.remove(id) }
  func setLoggingEnabled(_ enabled: Bool) { loggingEnabled = enabled }

  func start(coreCount: Int?, multipv: Int, setupCommands: [EngineCommand]?) throws {
    let session = try beginStart(coreCount: coreCount, multipv: multipv, setupCommands: setupCommands)
    guard handshake != nil else { return }
    retainReadinessUntilBarrier(sessionID: session)
  }

  private func retainReadinessUntilBarrier(sessionID: UUID) {
    keepsStartingWithoutWaiters = true
    if backgroundStartupTimer == nil {
      let clock = clock
      backgroundStartupTimer = Task { [weak self] in
        do { try await clock.sleep(for: .seconds(5)) }
        catch { return }
        await self?.startupExpired(sessionID: sessionID)
      }
    }
  }

  func startAndWaitUntilReady(coreCount: Int?, multipv: Int, setupCommands: [EngineCommand]?,
                            timeout: Duration, waiterOwner: UUID? = nil) async throws {
    try Task.checkCancellation()
    _ = try EngineInputValidation.timeoutMilliseconds(timeout)
    let session = try beginStart(coreCount: coreCount, multipv: multipv, setupCommands: setupCommands)
    do {
      try await waitUntilReady(sessionID: session, timeout: timeout, owner: waiterOwner)
    } catch is CancellationError {
      if sessionID == session, handshake != nil, readyWaiters.isEmpty, !keepsStartingWithoutWaiters {
        startAutomaticShutdown(sessionID: session)
      }
      throw CancellationError()
    }
  }

  private func beginStart(coreCount: Int?, multipv: Int, setupCommands: [EngineCommand]?) throws -> UUID {
    if let coreCount, coreCount < 1 { throw EngineError.invalidInput("The core count must be positive.") }
    guard multipv > 0 else { throw EngineError.invalidInput("MultiPV must be positive.") }
    let requested = Configuration(
      coreCount: max(coreCount ?? max(ProcessInfo.processInfo.processorCount - 1, 1), 1),
      multipv: multipv,
      commands: Engine.initialSetupCommands(descriptor: descriptor, setupCommands: setupCommands)
    )
    if let sessionID {
      guard terminalFailure == nil, shutdownTask == nil, state != .stopping else { throw EngineError.busy }
      guard configurationOperationID == nil, configuration == requested else { throw EngineError.busy }
      return sessionID
    }
    do {
      try descriptor.validateRequiredFiles()
      for command in requested.commands {
        try EngineInputValidation.command(command, descriptor: descriptor)
        switch command {
        case .setoption, .debug, .ucinewgame: break
        default: throw EngineError.invalidInput("Startup commands may only configure options, debug, or a new game.")
        }
      }
    } catch {
      let error = engineError(error)
      setState(.failed(error)); emit(.failure(error))
      finishStreams()
      throw error
    }
    prepareLegacyStreams()
    let session = UUID()
    sessionID = session
    configuration = requested
    options.removeAll()
    terminalFailure = nil
    handshake = .uci
    readinessAcknowledgements.removeAll()
    setState(.starting)
    do {
      try transport.start(sessionID: session) { [weak self] event in
        await self?.receive(event, sessionID: session)
      }
      setState(.handshaking)
      try enqueue(.uci, sessionID: session)
      return session
    } catch {
      failSession(engineError(error), sessionID: session)
      throw error
    }
  }

  private func waitUntilReady(sessionID: UUID, timeout: Duration, owner: UUID? = nil) async throws {
    if self.sessionID == sessionID, isRunning { return }
    if case let .failed(error) = state { throw error }
    guard self.sessionID == sessionID, handshake != nil else { throw EngineError.notReady }
    let id = UUID()
    let clock = clock
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let timer = Task { [weak self] in
          do { try await clock.sleep(for: timeout) }
          catch { return }
          await self?.readyWaiterExpired(id, sessionID: sessionID)
        }
        readyWaiters[id] = Waiter(continuation: continuation, timer: timer, owner: owner)
      }
    } onCancel: {
      Task { await self.cancelReadyWaiter(id, sessionID: sessionID) }
    }
  }

  private func readyWaiterExpired(_ id: UUID, sessionID: UUID) {
    guard self.sessionID == sessionID, let waiter = readyWaiters.removeValue(forKey: id) else { return }
    let error: EngineError = configurationOperationID == nil ? .startTimeout : .shutdownTimeout
    waiter.continuation.resume(throwing: error)
    if readyWaiters.isEmpty, !keepsStartingWithoutWaiters { failSession(error, sessionID: sessionID) }
  }
  private func cancelReadyWaiter(_ id: UUID, sessionID: UUID) {
    guard self.sessionID == sessionID, let waiter = readyWaiters.removeValue(forKey: id) else { return }
    waiter.timer.cancel(); waiter.continuation.resume(throwing: CancellationError())
    if readyWaiters.isEmpty, !keepsStartingWithoutWaiters, handshake != nil { startAutomaticShutdown(sessionID: sessionID) }
  }
  private func startupExpired(sessionID: UUID) {
    guard self.sessionID == sessionID, handshake != nil else { return }
    failSession(configurationOperationID == nil ? .startTimeout : .shutdownTimeout, sessionID: sessionID)
  }

  func sendChecked(command: EngineCommand) async throws {
    try Task.checkCancellation()
    try EngineInputValidation.command(command, descriptor: descriptor)
    if command == .quit { try await stopAndWait(timeout: .seconds(5)); return }
    if command == .stop { try await stopSearchAndWait(timeout: .seconds(5)); return }
    try admit(command, owner: nil)
  }

  /// Runs entirely inside the actor, including native enqueue: stop cannot overtake an admitted go.
  private func admit(_ command: EngineCommand, owner: UUID?) throws {
    if configurationOperationID != nil { throw EngineError.busy }
    guard let sessionID, isRunning, terminalFailure == nil, shutdownTask == nil else { throw EngineError.notReady }
    let invasive: Bool
    switch command {
    case .position, .go, .setoption, .ucinewgame, .uci: invasive = true
    default: invasive = false
    }
    if invasive, search != nil || (analysisReservation != nil && analysisReservation != owner) { throw EngineError.busy }
    if case let .setoption(id, value) = command { try validateRawOption(id: id, value: value) }
    if case .ponderhit = command {
      guard search?.pondering == true else { throw EngineError.invalidInput("There is no ponder search to continue.") }
    }
    if case .go(_, let pondering, _, _, _, _, _, _, _, _, _, _) = command {
      search = Search(id: owner ?? UUID(), continuation: nil, includeWDL: false, pondering: pondering)
      setState(.thinking)
    }
    if command == .stop { search?.stopRequested = true }
    do {
      try enqueue(command, sessionID: sessionID, readiness: .query)
      if command == .ponderhit { search?.pondering = false }
    } catch {
      if case EngineError.invalidInput = error {
        if case .go = command { search = nil; setState(.ready) }
        throw error
      }
      failSession(engineError(error), sessionID: sessionID)
      throw error
    }
  }

  func setOption(id: String, value: UCIOptionValue) async throws {
    try Task.checkCancellation()
    if configurationOperationID != nil { throw EngineError.busy }
    guard isRunning else { throw EngineError.notReady }
    try EngineInputValidation.text(id, label: "Option name")
    guard let descriptor = options[id.lowercased()] else { throw EngineError.unsupportedOption(id) }
    try EngineOptionValidation.typed(value, descriptor: descriptor)
    try await configureOptions([.setoption(id: descriptor.name, value: value.rawValue)], owner: nil)
  }

  private func configureOptions(_ commands: [EngineCommand], owner: UUID?) async throws {
    try Task.checkCancellation()
    guard let sessionID else { throw EngineError.notReady }
    for command in commands {
      try EngineInputValidation.command(command, descriptor: descriptor)
      if case let .setoption(id, value) = command { try validateRawOption(id: id, value: value) }
    }
    for command in commands { try admit(command, owner: owner) }
    configurationOperationID = UUID()
    handshake = .ready
    keepsStartingWithoutWaiters = true
    setState(.configuring)
    do { try enqueue(.isready, sessionID: sessionID) }
    catch { failSession(engineError(error), sessionID: sessionID); throw error }
    retainReadinessUntilBarrier(sessionID: sessionID)
    try await waitUntilReady(sessionID: sessionID, timeout: .seconds(5), owner: owner)
    try Task.checkCancellation()
  }
  private func validateRawOption(id: String, value: String?) throws {
    guard let descriptor = options[id.lowercased()] else { throw EngineError.unsupportedOption(id) }
    try EngineOptionValidation.raw(value, descriptor: descriptor)
  }

  nonisolated func analysisStream(_ request: AnalysisRequest) -> AsyncThrowingStream<AnalysisUpdate, Error> {
    let id = UUID()
    return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
      let producer = Task { [weak self] in
        do {
          try Task.checkCancellation()
          guard let self else { throw EngineError.notReady }
          try await self.beginAnalysis(request, id: id, continuation: continuation)
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { @Sendable [weak self] reason in
        guard case .cancelled = reason else { return }
        producer.cancel()
        Task { [weak self] in await self?.cancelAnalysis(id) }
      }
    }
  }

  private func beginAnalysis(_ request: AnalysisRequest, id: UUID,
                            continuation: AsyncThrowingStream<AnalysisUpdate, Error>.Continuation) async throws {
    try Task.checkCancellation()
    guard analysisReservation == nil, search == nil, shutdownTask == nil else { throw EngineError.busy }
    guard request.multipv > 0 else { throw EngineError.invalidInput("MultiPV must be positive.") }
    _ = try EngineInputValidation.timeoutMilliseconds(request.startupTimeout)
    try EngineInputValidation.command(.position(request.position, moves: request.moves), descriptor: descriptor)
    let command: EngineCommand
    switch request.limit {
    case .depth(let value): command = .go(searchmoves: request.searchMoves, depth: value)
    case .nodes(let value): command = .go(searchmoves: request.searchMoves, nodes: value)
    case .moveTime(let value): command = .go(searchmoves: request.searchMoves, movetime: value)
    case .infinite: command = .go(searchmoves: request.searchMoves, infinite: true)
    }
    try EngineInputValidation.command(command, descriptor: descriptor)
    analysisReservation = id
    do {
      if !isRunning {
        guard request.startsEngineIfNeeded else { throw EngineError.notReady }
        try await startAndWaitUntilReady(coreCount: nil, multipv: request.multipv, setupCommands: nil,
                                        timeout: request.startupTimeout, waiterOwner: id)
      }
      try Task.checkCancellation()
      guard analysisReservation == id else { throw CancellationError() }
      var commands: [EngineCommand] = [.setoption(id: "MultiPV", value: String(request.multipv))]
      if options["uci_showwdl"] != nil || request.includeWDL {
        commands.append(.setoption(id: "UCI_ShowWDL", value: request.includeWDL ? "true" : "false"))
      }
      try await configureOptions(commands, owner: id)
      try Task.checkCancellation()
      guard analysisReservation == id else { throw CancellationError() }
      try admit(.position(request.position, moves: request.moves), owner: id)
      try Task.checkCancellation()
      try admit(command, owner: id)
      search?.continuation = continuation
      search?.includeWDL = request.includeWDL
      analysisReservation = nil
    } catch {
      if analysisReservation == id { analysisReservation = nil }
      throw error
    }
  }

  private func cancelAnalysis(_ id: UUID) {
    if analysisReservation == id { analysisReservation = nil }
    guard search?.id == id else { return }
    search?.continuation?.finish(throwing: CancellationError())
    search?.continuation = nil
    Task { [weak self] in
      do { try await self?.stopSearchAndWait(timeout: .seconds(5), expectedSearchID: id) }
      catch { }
    }
  }

  func stopSearchAndWait(timeout: Duration, expectedSearchID: UUID? = nil) async throws {
    _ = try EngineInputValidation.timeoutMilliseconds(timeout)
    if let preparation = analysisReservation, expectedSearchID == nil || expectedSearchID == preparation {
      analysisReservation = nil
      // Keep the protocol barrier owned by this session even after cancelling its analysis waiter.
      // A later operation cannot reuse the old readyok as its own configuration acknowledgement.
      if let sessionID, handshake != nil { retainReadinessUntilBarrier(sessionID: sessionID) }
      let cancelled = readyWaiters.filter { $0.value.owner == preparation }
      for (id, waiter) in cancelled {
        readyWaiters.removeValue(forKey: id)
        waiter.timer.cancel(); waiter.continuation.resume(throwing: CancellationError())
      }
    }
    guard let current = search else { return }
    if let expectedSearchID, current.id != expectedSearchID { return }
    guard let sessionID, terminalFailure == nil, shutdownTask == nil else { throw EngineError.notReady }
    let id = UUID()
    let clock = clock
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let timer = Task { [weak self] in
          do { try await clock.sleep(for: timeout) }
          catch { return }
          await self?.searchWaiterExpired(id, sessionID: sessionID, searchID: current.id)
        }
        searchWaiters[id] = Waiter(continuation: continuation, timer: timer, owner: nil)
        if search?.stopRequested == false {
          search?.stopRequested = true
          do { try enqueue(.stop, sessionID: sessionID) }
          catch { failSession(engineError(error), sessionID: sessionID) }
        }
      }
    } onCancel: {
      Task { await self.cancelSearchWaiter(id) }
    }
  }
  private func cancelSearchWaiter(_ id: UUID) {
    if let waiter = searchWaiters.removeValue(forKey: id) {
      waiter.timer.cancel(); waiter.continuation.resume(throwing: CancellationError())
    }
  }
  private func searchWaiterExpired(_ id: UUID, sessionID: UUID, searchID: UUID) {
    guard self.sessionID == sessionID, search?.id == searchID,
          let waiter = searchWaiters.removeValue(forKey: id) else { return }
    waiter.continuation.resume(throwing: EngineError.shutdownTimeout)
    failSession(.shutdownTimeout, sessionID: sessionID)
  }

  func stopAndWait(timeout: Duration) async throws {
    _ = try EngineInputValidation.timeoutMilliseconds(timeout)
    guard let sessionID else {
      finishWaiters(&readyWaiters, throwing: CancellationError())
      finishWaiters(&searchWaiters, throwing: CancellationError())
      setState(.stopped); finishStreams()
      return
    }
    terminalFailure = nil
    beginShutdown(sessionID: sessionID)
    try await waitForShutdown(sessionID: sessionID, timeout: timeout)
    // A caller with a longer deadline can successfully finish a shutdown after another timed out.
    if self.sessionID == nil, terminalFailure == .shutdownTimeout {
      terminalFailure = nil; setState(.stopped)
    }
  }

  @discardableResult private func beginShutdown(sessionID: UUID) -> Task<Void, Error> {
    if let shutdownTask { return shutdownTask }
    backgroundStartupTimer?.cancel(); backgroundStartupTimer = nil
    handshake = nil; configurationOperationID = nil; keepsStartingWithoutWaiters = false; analysisReservation = nil
    finishWaiters(&readyWaiters, throwing: CancellationError())
    finishWaiters(&searchWaiters, throwing: CancellationError())
    let searchError: Error = terminalFailure.map { $0 as Error } ?? CancellationError()
    search?.continuation?.finish(throwing: searchError)
    search = nil
    if terminalFailure == nil { setState(.stopping) }
    transport.requestStop(sessionID: sessionID)
    let transport = transport
    let task = Task { [weak self] in
      do {
        while true {
          do { try await transport.waitUntilStopped(sessionID: sessionID, timeout: .seconds(5)); break }
          catch EngineError.shutdownTimeout { continue }
        }
        await self?.shutdownCompleted(sessionID: sessionID, error: nil)
      } catch {
        await self?.shutdownCompleted(sessionID: sessionID, error: error)
        throw error
      }
    }
    shutdownTask = task
    return task
  }

  private func waitForShutdown(sessionID: UUID, timeout: Duration) async throws {
    guard self.sessionID == sessionID else { return }
    let id = UUID()
    let clock = clock
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let timer = Task { [weak self] in
          do { try await clock.sleep(for: timeout) }
          catch { return }
          await self?.shutdownWaiterExpired(id, sessionID: sessionID)
        }
        shutdownWaiters[id] = Waiter(continuation: continuation, timer: timer, owner: nil)
      }
    } onCancel: { Task { await self.cancelShutdownWaiter(id) } }
  }

  private func shutdownWaiterExpired(_ id: UUID, sessionID: UUID) {
    guard self.sessionID == sessionID, let waiter = shutdownWaiters.removeValue(forKey: id) else { return }
    waiter.continuation.resume(throwing: EngineError.shutdownTimeout)
    if terminalFailure == nil {
      terminalFailure = .shutdownTimeout
      setState(.failed(.shutdownTimeout)); emit(.failure(.shutdownTimeout))
    }
  }
  private func cancelShutdownWaiter(_ id: UUID) {
    guard let waiter = shutdownWaiters.removeValue(forKey: id) else { return }
    waiter.timer.cancel(); waiter.continuation.resume(throwing: CancellationError())
  }
  private func shutdownCompleted(sessionID: UUID, error: Error?) {
    guard self.sessionID == sessionID else { return }
    shutdownTask = nil
    if let error {
      if terminalFailure == nil {
        terminalFailure = engineError(error)
        setState(.failed(engineError(error))); emit(.failure(engineError(error)))
      }
      finishWaiters(&shutdownWaiters, throwing: error)
    } else {
      self.sessionID = nil; shutdownTask = nil; configuration = nil
      if let terminalFailure { setState(.failed(terminalFailure)) }
      else { setState(.stopped) }
      finishStreams()
      finishWaiters(&shutdownWaiters)
    }
  }
  private func startAutomaticShutdown(sessionID: UUID) {
    beginShutdown(sessionID: sessionID)
  }
  func shutdownForDeinitialization() async {
    while sessionID != nil {
      do { try await stopAndWait(timeout: .seconds(5)) }
      catch {
        // Keep the runtime and callback owner alive until the native worker is actually joined.
        try? await clock.sleep(for: .milliseconds(100))
      }
    }
    finishStreams()
  }

  private func receive(_ event: EngineTransportEvent, sessionID: UUID) {
    guard self.sessionID == sessionID else { return }
    switch event {
    case .droppedDiagnostics(let count):
      recordDropped(count, channel: .nativeDiagnostics)
    case .completed:
      if shutdownTask == nil {
        if terminalFailure == nil { failSession(.engineExitedUnexpectedly, sessionID: sessionID) }
        else { startAutomaticShutdown(sessionID: sessionID) }
      }
    case .failure(let error):
      failSession(error, sessionID: sessionID)
    case .output(let output):
      for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
        let raw = String(line).replacingOccurrences(of: "\r", with: "")
        guard !raw.isEmpty else { continue }
        let response = EngineResponse(rawValue: raw)
        if let response, terminalFailure == nil { handleResponse(response, sessionID: sessionID) }
        let value = EngineOutput(rawValue: raw, response: response)
        recordDropped(dropped(legacyOutputContinuation?.yield(value)) + outputSubscriptions.publish(value), channel: .outputs)
        emit(.rawResponseReceived(raw))
        if let response {
          emit(.responseParsed(response))
          recordDropped(dropped(legacyResponseContinuation?.yield(response)) + responseSubscriptions.publish(response), channel: .responses)
        } else { emit(.responseIgnored(raw)) }
        if loggingEnabled { logger.debug("\(raw, privacy: .public)") }
      }
    }
  }

  private func handleResponse(_ response: EngineResponse, sessionID: UUID) {
    switch response {
    case .option(let option):
      guard options.count < 256 || options[option.name.lowercased()] != nil else {
        failSession(.bufferOverflow, sessionID: sessionID); return
      }
      options[option.name.lowercased()] = option
    case .uciok:
      guard handshake == .uci, let configuration else { return }
      setState(.configuring)
      do {
        for command in configuration.commands {
          if case let .setoption(id, value) = command { try validateRawOption(id: id, value: value) }
          try enqueue(command, sessionID: sessionID)
        }
        try validateRawOption(id: "Threads", value: String(configuration.coreCount))
        try enqueue(.setoption(id: "Threads", value: String(configuration.coreCount)), sessionID: sessionID)
        try validateRawOption(id: "MultiPV", value: String(configuration.multipv))
        try enqueue(.setoption(id: "MultiPV", value: String(configuration.multipv)), sessionID: sessionID)
        handshake = .ready
        try enqueue(.isready, sessionID: sessionID)
      } catch { failSession(engineError(error), sessionID: sessionID) }
    case .readyok:
      guard !readinessAcknowledgements.isEmpty else { return }
      let acknowledgement = readinessAcknowledgements.removeFirst()
      guard case .barrier = acknowledgement, handshake == .ready else { return }
      handshake = nil; configurationOperationID = nil; keepsStartingWithoutWaiters = false
      backgroundStartupTimer?.cancel(); backgroundStartupTimer = nil
      setState(.ready)
      finishWaiters(&readyWaiters)
    case .info(let info):
      let result = search?.continuation?.yield(AnalysisUpdate(depth: info.depth, multipv: info.multipv, score: info.score,
                                                            principalVariation: info.pv ?? [], nodes: info.nodes,
                                                            nps: info.nps, wdl: search?.includeWDL == true ? info.wdl : nil))
      if case .dropped? = result { recordDropped(1, channel: .analysis) }
    case .bestmove(let move, let ponder):
      guard let current = search else { return }
      search = nil
      if shutdownTask == nil { setState(.ready) }
      if case .dropped? = current.continuation?.yield(AnalysisUpdate(bestMove: move, ponder: ponder)) {
        recordDropped(1, channel: .analysis)
      }
      current.continuation?.finish()
      finishWaiters(&searchWaiters)
    default: break
    }
  }

  private func enqueue(_ command: EngineCommand, sessionID: UUID,
                       readiness: ReadinessAcknowledgement = .barrier) throws {
    var canonical = command
    if case let .setoption(id, value) = command, let descriptor = options[id.lowercased()] {
      canonical = .setoption(id: descriptor.name, value: value)
    }
    if canonical == .isready {
      guard readinessAcknowledgements.count < 256 else { throw EngineError.bufferOverflow }
      // Reserve before sending: a synchronous native callback cannot overtake admission.
      readinessAcknowledgements.append(readiness)
    }
    do { try transport.send(canonical.rawValue, sessionID: sessionID) }
    catch {
      if canonical == .isready { readinessAcknowledgements.removeLast() }
      throw error
    }
    if case let .setoption(id, value) = canonical, let value, let number = Int(value) {
      if id == "MultiPV" { configuration?.multipv = number }
      if id == "Threads" { configuration?.coreCount = number }
    }
    emit(.commandSent(canonical.rawValue))
    if loggingEnabled { logger.debug("\(canonical.rawValue, privacy: .public)") }
  }
  private func failSession(_ error: EngineError, sessionID: UUID) {
    guard self.sessionID == sessionID, terminalFailure == nil else { return }
    terminalFailure = error
    setState(.failed(error)); emit(.failure(error))
    finishWaiters(&readyWaiters, throwing: error)
    finishWaiters(&searchWaiters, throwing: error)
    search?.continuation?.finish(throwing: error); search = nil
    startAutomaticShutdown(sessionID: sessionID)
  }
  func reportOperationError(_ error: Error) {
    guard !(error is CancellationError) else { return }
    let value = engineError(error)
    emit(.failure(value))
    if state == .idle { setState(.failed(value)) }
  }
  private func engineError(_ error: Error) -> EngineError { error as? EngineError ?? .nativeFailure(String(describing: error)) }
  private func setState(_ state: EngineState) { self.state = state; emit(.stateChanged(state)) }
  private func emit(_ event: EngineEvent, diagnoseDrops: Bool = true) {
    let count = dropped(legacyEventContinuation?.yield(event)) + eventSubscriptions.publish(event)
    recordDropped(count, channel: .events, diagnose: diagnoseDrops)
  }
  private func dropped<Value>(_ result: AsyncStream<Value>.Continuation.YieldResult?) -> Int {
    if case .dropped? = result { return 1 }
    return 0
  }
  private func recordDropped(_ count: Int, channel: EngineBufferChannel, diagnose: Bool = true) {
    guard count > 0 else { return }
    bufferStatistics.record(count, channel: channel)
    let now = ContinuousClock.now
    guard diagnose, lastOverflowDiagnostic == nil || now - lastOverflowDiagnostic! >= .seconds(1) else { return }
    lastOverflowDiagnostic = now
    // Directly count a dropped diagnostic; never generate another diagnostic from that drop.
    emit(.log(level: .warning, message: "Bounded engine buffers dropped updates. Inspect bufferStatistics for delivery counts."),
         diagnoseDrops: false)
  }

  private func finishWaiters(_ waiters: inout [UUID: Waiter], throwing error: Error? = nil) {
    let values = Array(waiters.values)
    waiters.removeAll()
    for waiter in values {
      waiter.timer.cancel()
      if let error { waiter.continuation.resume(throwing: error) }
      else { waiter.continuation.resume() }
    }
  }
  private func prepareLegacyStreams() {
    if legacyResponseStream == nil {
      (legacyResponseStream, legacyResponseContinuation) = AsyncStream<EngineResponse>.makeStream(bufferingPolicy: .bufferingNewest(256))
    }
    if legacyOutputStream == nil {
      (legacyOutputStream, legacyOutputContinuation) = AsyncStream<EngineOutput>.makeStream(bufferingPolicy: .bufferingNewest(256))
    }
    if legacyEventStream == nil {
      (legacyEventStream, legacyEventContinuation) = AsyncStream<EngineEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
    }
  }
  private func finishStreams() {
    legacyResponseContinuation?.finish(); legacyResponseStream = nil; legacyResponseContinuation = nil
    legacyOutputContinuation?.finish(); legacyOutputStream = nil; legacyOutputContinuation = nil
    legacyEventContinuation?.finish(); legacyEventStream = nil; legacyEventContinuation = nil
    responseSubscriptions.finish(); outputSubscriptions.finish(); eventSubscriptions.finish()
  }
}
