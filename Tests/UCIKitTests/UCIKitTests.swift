import Foundation
import Testing
@testable import UCIKit
import UCIKitProcess

/// A scripted engine: answers the handshake and a search with fixed lines.
final class ScriptedTransport: UCITransport, @unchecked Sendable {
  var capabilities: EngineTransportCapabilities { .embedded }
  private let lock = NSLock()
  private var mailbox: UCITransportMailbox?
  private(set) var sent: [String] = []

  func start(sessionID: UUID, handler: @escaping @Sendable (UCITransportEvent) async -> Void) throws {
    let mailbox = UCITransportMailbox()
    mailbox.deliver(to: handler)
    lock.withLock { self.mailbox = mailbox }
  }

  func send(_ command: String, sessionID: UUID) throws {
    let mailbox = lock.withLock { sent.append(command); return self.mailbox }
    switch command {
    case "uci":
      mailbox?.appendLines("id name Scripted 1\nid author Test\noption name Threads type spin default 1 min 1 max 8\noption name MultiPV type spin default 1 min 1 max 4\noption name UCI_ShowWDL type check default false\nuciok")
    case "isready":
      mailbox?.append(.output("readyok"))
    case _ where command.hasPrefix("go"):
      mailbox?.appendLines("info depth 5 seldepth 7 multipv 1 score cp 31 wdl 120 800 80 nodes 1000 nps 50000 pv e2e4 e7e5\nbestmove e2e4 ponder e7e5")
    case "quit":
      mailbox?.append(.completed)
    default: break
    }
  }

  func requestStop(sessionID: UUID) {
    let mailbox = lock.withLock { self.mailbox }
    mailbox?.append(.completed)
  }

  func waitUntilStopped(sessionID: UUID, timeout: Duration) async throws {}
}

@Suite struct UCIKitTests {
  @Test func analysisThroughAnyTransport() async throws {
    let transport = ScriptedTransport()
    let engine = Engine(descriptor: EngineDescriptor(id: "scripted", name: "Scripted", version: "1"), transport: transport)
    var last: AnalysisUpdate?
    for try await update in engine.analyze(AnalysisRequest(position: .startpos, limit: .depth(5), includeWDL: true)) {
      last = update
    }
    #expect(last?.bestMove == "e2e4")
    #expect(transport.sent.contains("uci"))
    try await engine.stopAndWait()
  }

  @Test func descriptorLimitsRejectLargeNodeCounts() throws {
    let descriptor = EngineDescriptor(id: "x", name: "X", version: "1", maximumNodes: Int(Int32.max))
    #expect(throws: EngineError.self) {
      try EngineInputValidation.command(.go(nodes: Int(Int32.max) + 1), descriptor: descriptor)
    }
    try EngineInputValidation.command(.go(nodes: 1000), descriptor: descriptor)
  }

  @Test func missingRequiredFileFailsTheStart() async throws {
    let descriptor = EngineDescriptor(id: "x", name: "X", version: "1", requiredFiles: [URL(fileURLWithPath: "/nonexistent/net.pnn")])
    let engine = Engine(descriptor: descriptor, transport: ScriptedTransport())
    await #expect(throws: EngineError.self) {
      try await engine.startAndWaitUntilReady()
    }
  }

  #if os(macOS)
  /// Runs a real engine binary as a separate program. Set `UCIKIT_ENGINE` to its path (and
  /// `UCIKIT_ENGINE_EVALFILE` when it needs a network file).
  @Test(.enabled(if: ProcessInfo.processInfo.environment["UCIKIT_ENGINE"] != nil))
  func externalProcessEngine() async throws {
    let env = ProcessInfo.processInfo.environment
    let url = URL(fileURLWithPath: env["UCIKIT_ENGINE"]!)
    let probe = try await UCIProbe.run(ProcessTransport(executable: url))
    #expect(probe.name != nil)
    #expect(probe.options.contains { $0.name == "Threads" })

    var setup: [EngineCommand] = [.setoption(id: "Hash", value: "64")]
    if let evalFile = env["UCIKIT_ENGINE_EVALFILE"] { setup.append(.setoption(id: "EvalFile", value: evalFile)) }
    let engine = Engine(descriptor: EngineDescriptor(id: "external", name: probe.name ?? "?", version: "", setupCommands: setup),
                        transport: ProcessTransport(executable: url))
    var last: AnalysisUpdate?
    for try await update in engine.analyze(AnalysisRequest(position: .startpos, limit: .depth(12))) { last = update }
    #expect(last?.bestMove?.count == 4)
    try await engine.stopAndWait()
  }
  #endif
}
