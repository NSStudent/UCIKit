//
//  EngineResponseParser.swift
//  UCIKit
//

enum EngineResponseParser {

  static func parse(response: String) -> EngineResponse? {
    let tokens = response.split { $0.isWhitespace || $0.isNewline }.map(String.init)
    var iterator = tokens.makeIterator()

    guard let command = iterator.next() else {
      return nil
    }

    switch command {
    case "id": return parseID(&iterator)
    case "uciok": return .uciok
    case "readyok": return .readyok
    case "bestmove": return parseBestMove(&iterator)
    case "info": return parseInfo(&iterator)
    case "option": return parseOption(&iterator)
    case "copyprotection": return parseCopyProtection(&iterator)
    case "registration": return parseRegistration(&iterator)
    default: return .unknown(response)
    }
  }

  // MARK: - Private

  private static func parseID(_ iterator: inout IndexingIterator<[String]>) -> EngineResponse? {
    switch iterator.next() {
    case "name": return .id(.name(iterator.joined(separator: " ")))
    case "author": return .id(.author(iterator.joined(separator: " ")))
    default: return nil
    }
  }

  private static func parseBestMove(_ iterator: inout IndexingIterator<[String]>) -> EngineResponse? {
    guard let move = iterator.next() else { return nil }

    var ponder: String?
    if iterator.next() == "ponder" {
      ponder = iterator.next()
    }

    return .bestmove(move: move, ponder: ponder)
  }

  private static func parseInfo(_ iterator: inout IndexingIterator<[String]>) -> EngineResponse? {
    let tokens = Array(iterator)
    let fields = Set(EngineResponse.Info.Argument.allCases.map(\.rawValue))
    var info = EngineResponse.Info()
    var index = 0
    func single() -> String? {
      guard index < tokens.count, !fields.contains(tokens[index]) else { return nil }
      defer { index += 1 }
      return tokens[index]
    }
    func multiple() -> [String] {
      let start = index
      while index < tokens.count, !fields.contains(tokens[index]) { index += 1 }
      return Array(tokens[start..<index])
    }
    while index < tokens.count {
      let field = tokens[index]
      index += 1
      switch field {
      case "string":
        info.string = tokens[index...].joined(separator: " ")
        index = tokens.count
      case "wdl":
        let values = (0..<3).map { _ in single().flatMap(Int.init) }
        if let w = values[0], let d = values[1], let l = values[2] {
          info.wdl = .init(win: w, draw: d, loss: l)
        }
      case "score":
        var score = EngineResponse.Info.Score()
        while index < tokens.count, !fields.contains(tokens[index]) {
          let part = tokens[index]
          index += 1
          switch part {
          case "cp": score.cp = single().flatMap(Double.init)
          case "mate": score.mate = single().flatMap(Int.init)
          case "lowerbound": score.lowerbound = true
          case "upperbound": score.upperbound = true
          default: break
          }
        }
        info.score = score
      case "pv": info.pv = multiple()
      case "refutation": info.refutation = multiple()
      case "currline":
        let cpu = single().flatMap(Int.init)
        info.currline = .init(cpunr: cpu, moves: multiple())
      case "depth": info.depth = single().flatMap(Int.init)
      case "seldepth": info.seldepth = single().flatMap(Int.init)
      case "time": info.time = single().flatMap(Int.init)
      case "nodes": info.nodes = single().flatMap(Int.init)
      case "multipv": info.multipv = single().flatMap(Int.init)
      case "currmove": info.currmove = single()
      case "currmovenumber": info.currmovenumber = single().flatMap(Int.init)
      case "hashfull": info.hashfull = single().flatMap(Double.init)
      case "nps": info.nps = single().flatMap(Int.init)
      case "tbhits": info.tbhits = single().flatMap(Int.init)
      case "sbhits": info.sbhits = single().flatMap(Int.init)
      case "cpuload": info.cpuload = single().flatMap(Int.init)
      case "movesleft": info.movesLeft = single().flatMap(Double.init)
      default: break
      }
    }
    return .info(info)
  }

  private static func parseOption(_ iterator: inout IndexingIterator<[String]>) -> EngineResponse? {
    var fields: [String: [String]] = [:]
    var vars: [[String]] = []
    var activeField: String?

    let fieldNames = ["name", "type", "default", "min", "max", "var"]
    var token = iterator.next()

    while let current = token {
      if fieldNames.contains(current) {
        activeField = current
        if current == "var" {
          vars.append([])
        } else if fields[current] == nil {
          fields[current] = []
        }
      } else if let activeField {
        if activeField == "var" {
          if vars.isEmpty {
            vars.append([])
          }
          vars[vars.count - 1].append(current)
        } else {
          fields[activeField, default: []].append(current)
        }
      }

      token = iterator.next()
    }

    guard let name = fields["name"]?.joined(separator: " "), !name.isEmpty else {
      return nil
    }

    let typeRawValue = fields["type"]?.joined(separator: " ") ?? ""
    let type = EngineResponse.OptionType(rawValue: typeRawValue) ?? .unknown

    return .option(
      .init(
        name: name,
        type: type,
        defaultValue: fields["default"]?.joined(separator: " "),
        min: fields["min"].flatMap { Int($0.joined(separator: " ")) },
        max: fields["max"].flatMap { Int($0.joined(separator: " ")) },
        vars: vars.map { $0.joined(separator: " ") }.filter { !$0.isEmpty }
      ))
  }

  private static func parseCopyProtection(
    _ iterator: inout IndexingIterator<[String]>
  ) -> EngineResponse {
    let rawValue = iterator.next() ?? ""
    let status = EngineResponse.CopyProtection(rawValue: rawValue) ?? .unknown
    return .copyProtection(status)
  }

  private static func parseRegistration(
    _ iterator: inout IndexingIterator<[String]>
  ) -> EngineResponse {
    let rawValue = iterator.next() ?? ""
    let status = EngineResponse.Registration(rawValue: rawValue) ?? .unknown
    return .registration(status)
  }

  /// Maps `value` to appropriate type depending on `key`.
  private static func map(_ value: Any?, for key: String) -> Any? {
    guard let argument = EngineResponse.Info.Argument(rawValue: key),
      let value
    else {
      return nil
    }

    switch argument {
    case .wdl: return value as? EngineResponse.Info.WDL
    case .movesleft: return Double(value as? String ?? "")
    case .depth: return Int(value as? String ?? "")
    case .seldepth: return Int(value as? String ?? "")
    case .time: return Int(value as? String ?? "")
    case .nodes: return Int(value as? String ?? "")
    case .pv: return value as? [String]
    case .multipv: return Int(value as? String ?? "")
    case .score: return value as? EngineResponse.Info.Score
    case .currmove: return value as? String
    case .currmovenumber: return Int(value as? String ?? "")
    case .hashfull: return Double(value as? String ?? "")
    case .nps: return Int(value as? String ?? "")
    case .tbhits: return Int(value as? String ?? "")
    case .sbhits: return Int(value as? String ?? "")
    case .cpuload: return Int(value as? String ?? "")
    case .string: return value as? String
    case .refutation: return value as? [String]
    case .currline: return value as? EngineResponse.Info.CurrLine
    }
  }

}
