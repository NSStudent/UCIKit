import Foundation

/// Identity and limits of one UCI engine, independent of how its text is carried.
public struct EngineDescriptor: Equatable, Sendable {
  /// Stable identifier, for example `caissa`, `stockfish-wasm` or an external engine's id.
  public var id: String
  /// Name shown to people, for example `Caissa 2.0.21`.
  public var name: String
  public var version: String
  /// Commands sent after `uci` when the caller passes none (`EvalFile`, `SyzygyPath`…).
  public var setupCommands: [EngineCommand]
  /// Files that must exist before the engine starts (its network, for example).
  public var requiredFiles: [URL]
  /// Highest full-move number the engine accepts in a FEN.
  public var maximumFullmove: Int
  /// Highest `go nodes` the engine parses safely, when it is lower than `Int.max`.
  public var maximumNodes: Int?

  public init(
    id: String,
    name: String,
    version: String,
    setupCommands: [EngineCommand] = [],
    requiredFiles: [URL] = [],
    maximumFullmove: Int = 100_000,
    maximumNodes: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.setupCommands = setupCommands
    self.requiredFiles = requiredFiles
    self.maximumFullmove = maximumFullmove
    self.maximumNodes = maximumNodes
  }

  func validateRequiredFiles(fileManager: FileManager = .default) throws {
    for url in requiredFiles {
      var isDirectory: ObjCBool = false
      guard url.isFileURL, fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
        throw EngineError.missingResource(url)
      }
    }
  }
}
