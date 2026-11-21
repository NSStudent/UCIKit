# UCIKit

Talk UCI to any chess engine from Swift, whatever carries the text.

UCIKit is the engine layer of [MindChess](https://mindchess.app). It contains **no engine**: it starts one, sends it
UCI commands, parses what it answers and streams the analysis back with Swift concurrency. The engine itself is
always a separate thing — a library you link, a WebAssembly file, or a program — and keeps its own licence.

| Product | What it carries | Platforms |
| --- | --- | --- |
| `UCIKit` | The engine actor, UCI commands, the response parser, analysis streams, and the `UCITransport` protocol | iOS 18, macOS 15, Mac Catalyst 18 |
| `UCIKitWeb` | A WebAssembly engine (for example stockfish.js) in a hidden `WKWebView`, served from `127.0.0.1` with COOP/COEP so multi-threaded builds get `SharedArrayBuffer` | iOS, macOS, Mac Catalyst |
| `UCIKitProcess` | A separate engine program over pipes (`posix_spawn`, security-scoped URLs) | macOS, Mac Catalyst (iOS cannot start processes) |

## Installation

```swift
.package(url: "https://github.com/NSStudent/UCIKit.git", from: "0.1.0"),
```

## Usage

```swift
import UCIKit
import UCIKitProcess

let engine = Engine(
    descriptor: EngineDescriptor(id: "stockfish", name: "Stockfish", version: "19"),
    transport: ProcessTransport(executable: URL(fileURLWithPath: "/path/to/stockfish"))
)
try await engine.startAndWaitUntilReady(multipv: 2)

let request = AnalysisRequest(position: .startpos, moves: ["e2e4"], limit: .depth(20), multipv: 2)
for try await update in engine.analyze(request) {
    print(update.depth ?? 0, update.score as Any, update.principalVariation.prefix(5))
}
await engine.stop()
```

A WebAssembly engine works the same way: pass a `WebViewTransport(engineDirectory:script:fallbackScript:)` pointing
at the folder with the engine's `.js` and `.wasm`. On iOS, set `WebViewTransport.hostView` so the hidden web view
lives in a window (WebKit throttles web views outside one).

Your own transport only has to conform to `UCITransport`: start a session, send lines, and deliver what the engine
writes through `UCITransportMailbox`.

## Licence

MIT (see `LICENSE`). Engines you use through UCIKit keep their own licences: Stockfish, for example, is GPL v3, and
whoever distributes it has to follow that licence.
