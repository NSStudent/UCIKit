import Foundation
import Testing
import UCIKit
import UCIKitWeb

/// Runs a WebAssembly build in a web view. Set `UCIKIT_WASM_DIR` to a folder with stockfish.js files
/// (for example stockfish-19-lite.js and stockfish-19-lite-single.js with their .wasm).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["UCIKIT_WASM_DIR"] != nil))
struct WebViewTransportTests {
  @Test @MainActor func stockfishWasmAnalyses() async throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["UCIKIT_WASM_DIR"]!)
    let transport = WebViewTransport(engineDirectory: directory, script: "stockfish-19-lite.js", fallbackScript: "stockfish-19-lite-single.js")
    let engine = Engine(descriptor: EngineDescriptor(id: "stockfish-wasm", name: "Stockfish", version: "19"), transport: transport)
    var last: AnalysisUpdate?
    var sawWDL = false
    for try await update in engine.analyze(AnalysisRequest(position: .startpos, limit: .depth(14), includeWDL: true, startupTimeout: .seconds(60))) {
      last = update
      if update.wdl != nil { sawWDL = true }
    }
    #expect(last?.bestMove?.count == 4)
    #expect(sawWDL)
    try await engine.stopAndWait()
  }
}
