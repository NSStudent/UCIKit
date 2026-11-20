import Foundation

enum EngineInputValidation {
  static func text(_ value: String, label: String) throws {
    guard value.utf8.count <= 65_536,
          !value.utf8.contains(where: { $0 < 32 || $0 == 127 }) else {
      throw EngineError.invalidInput("\(label) contains a control character or exceeds 64 KiB.")
    }
  }

  static func command(_ command: EngineCommand, descriptor: EngineDescriptor? = nil) throws {
    try text(command.rawValue, label: "Command")
    switch command {
    case .position(let position, let moves):
      if case let .fen(fen) = position { try validateFEN(fen, descriptor: descriptor) }
      for move in moves ?? [] { try validateMove(move) }
    case .setoption(let id, _):
      guard !id.trimmingCharacters(in: .whitespaces).isEmpty else { throw EngineError.invalidOption("An option name is required.") }
    case .go(let moves, _, let wtime, let btime, let winc, let binc, let movesToGo,
             let depth, let nodes, let mate, let moveTime, _):
      for move in moves ?? [] { try validateMove(move) }
      for number in [wtime, btime, winc, binc, moveTime].compactMap({ $0 }) {
        guard number >= 0, number <= Int(Int32.max) else { throw EngineError.invalidInput("Clock values must fit a nonnegative 32-bit integer.") }
      }
      for number in [movesToGo, depth, mate].compactMap({ $0 }) {
        guard number > 0, number <= Int(Int32.max) else { throw EngineError.invalidInput("Search limits must be positive 32-bit integers.") }
      }
      if let nodes, nodes <= 0 { throw EngineError.invalidInput("The node limit must be positive.") }
      // Some engines parse nodes as a 32-bit integer. Reject before enqueueing so an
      // otherwise valid search limit cannot terminate an embedded session.
      if let limit = descriptor?.maximumNodes, let nodes, nodes > limit {
        throw EngineError.invalidInput("The node limit of \(descriptor?.name ?? "this engine") is \(limit).")
      }
    default: break
    }
  }

  static func validateMove(_ move: String) throws {
    let bytes = Array(move.utf8)
    guard bytes.count == 4 || bytes.count == 5,
          (97...104).contains(bytes[0]), (49...56).contains(bytes[1]),
          (97...104).contains(bytes[2]), (49...56).contains(bytes[3]),
          bytes.count == 4 || [UInt8(113), 114, 98, 110].contains(bytes[4]) else {
      throw EngineError.invalidInput("Invalid UCI move: \(move).")
    }
  }

  private static func validateFEN(_ fen: String, descriptor: EngineDescriptor?) throws {
    try text(fen, label: "FEN")
    let fields = fen.split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count == 6 else { throw EngineError.invalidInput("A FEN must contain six fields.") }
    let ranks = fields[0].split(separator: "/", omittingEmptySubsequences: false)
    guard ranks.count == 8 else { throw EngineError.invalidInput("A FEN board must contain eight ranks.") }
    var whiteKings = 0
    var blackKings = 0
    for rank in ranks {
      var files = 0
      for piece in rank.utf8 {
        if (49...56).contains(piece) { files += Int(piece - 48) }
        else if Array("prnbqkPRNBQK".utf8).contains(piece) {
          files += 1
          if piece == 75 { whiteKings += 1 }
          if piece == 107 { blackKings += 1 }
        } else { throw EngineError.invalidInput("A FEN board contains an unknown piece.") }
      }
      guard files == 8 else { throw EngineError.invalidInput("Every FEN rank must contain eight squares.") }
    }
    guard whiteKings == 1, blackKings == 1, fields[1] == "w" || fields[1] == "b" else {
      throw EngineError.invalidInput("A FEN requires one king of each color and a valid active color.")
    }
    guard fields[2] == "-" || fields[2].utf8.allSatisfy({ Array("KQkqABCDEFGHabcdefgh".utf8).contains($0) }) else {
      throw EngineError.invalidInput("Invalid FEN castling rights.")
    }
    if fields[3] != "-" {
      let square = Array(fields[3].utf8)
      guard square.count == 2, (97...104).contains(square[0]), square[1] == 51 || square[1] == 54 else {
        throw EngineError.invalidInput("Invalid FEN en passant square.")
      }
    }
    guard let halfmove = Int(fields[4]), halfmove >= 0, halfmove <= Int(Int32.max),
          let fullmove = Int(fields[5]), fullmove > 0, fullmove <= Int(Int32.max) else {
      throw EngineError.invalidInput("Invalid FEN move counters.")
    }
    if let descriptor {
      let maximumFullmove = descriptor.maximumFullmove
      guard halfmove <= 32_767, fullmove <= maximumFullmove else {
        throw EngineError.invalidInput("The FEN move counters exceed the embedded engine's supported range.")
      }
    }
  }

  static func timeoutMilliseconds(_ timeout: Duration) throws -> UInt64 {
    guard timeout > .zero else { throw EngineError.invalidInput("The timeout must be positive.") }
    let components = timeout.components
    guard components.seconds >= 0,
          UInt64(components.seconds) <= UInt64(Int64.max) / 1_000 else {
      throw EngineError.invalidInput("The timeout is too large.")
    }
    let milliseconds = UInt64(components.seconds) * 1_000
    let fractional = UInt64(max(components.attoseconds, 0)) / 1_000_000_000_000_000
    guard milliseconds <= UInt64(Int64.max) - fractional else { throw EngineError.invalidInput("The timeout is too large.") }
    return max(milliseconds + fractional, 1)
  }
}

enum EngineOptionValidation {
  static func typed(_ value: UCIOptionValue, descriptor: EngineResponse.Option) throws {
    let rawValue = value.rawValue
    if let rawValue { try EngineInputValidation.text(rawValue, label: "Option value") }
    let matches: Bool
    switch (descriptor.type, value) {
    case (.check, .check), (.spin, .spin), (.combo, .combo), (.string, .string), (.button, .button): matches = true
    default: matches = false
    }
    guard matches else { throw EngineError.invalidOption("\(descriptor.name) requires a \(descriptor.type.rawValue) value.") }
    if case let .spin(number) = value {
      if let minimum = descriptor.min, number < minimum { throw EngineError.invalidOption("\(descriptor.name) is below its advertised minimum.") }
      if let maximum = descriptor.max, number > maximum { throw EngineError.invalidOption("\(descriptor.name) exceeds its advertised maximum.") }
    }
    if case let .combo(choice) = value, !descriptor.vars.contains(choice) {
      throw EngineError.invalidOption("\(choice) is not an advertised choice for \(descriptor.name).")
    }
  }

  static func raw(_ rawValue: String?, descriptor: EngineResponse.Option) throws {
    let value: UCIOptionValue
    switch descriptor.type {
    case .button:
      guard rawValue == nil || rawValue == "" else { throw EngineError.invalidOption("Button options do not take a value.") }
      value = .button
    case .check:
      guard let rawValue, rawValue == "true" || rawValue == "false" else { throw EngineError.invalidOption("Check options require true or false.") }
      value = .check(rawValue == "true")
    case .spin:
      guard let rawValue, let number = Int(rawValue) else { throw EngineError.invalidOption("Spin options require an integer.") }
      value = .spin(number)
    case .combo:
      guard let rawValue else { throw EngineError.invalidOption("Combo options require a choice.") }
      value = .combo(rawValue)
    case .string:
      value = .string(rawValue ?? "")
    case .unknown:
      throw EngineError.unsupportedOption(descriptor.name)
    }
    try typed(value, descriptor: descriptor)
  }
}
