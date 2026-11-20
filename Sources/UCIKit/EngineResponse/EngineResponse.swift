//
//  EngineResponse.swift
//  UCIKit
//

/// Possible engine responses based on the
/// [Universal Chess Interface (UCI)](https://backscattering.de/chess/uci/2006-04.txt).
public enum EngineResponse: Sendable {

  /// `"id name <x>"`, `"id author <x>"`
  ///
  /// See [UCI protocol documentation](https://backscattering.de/chess/uci/2006-04.txt)
  /// for more information.
  case id(ID)

  /// `"uciok"`
  ///
  /// See [UCI protocol documentation](https://backscattering.de/chess/uci/2006-04.txt)
  /// for more information.
  case uciok

  /// `"readyok"`
  ///
  /// See [UCI protocol documentation](https://backscattering.de/chess/uci/2006-04.txt)
  /// for more information.
  case readyok

  /// `"bestmove <move1> [ ponder <move2> ]"`
  ///
  /// See [UCI protocol documentation](https://backscattering.de/chess/uci/2006-04.txt)
  /// for more information.
  case bestmove(move: String, ponder: String?)

  /// `"info"`
  ///
  /// See [UCI protocol documentation](https://backscattering.de/chess/uci/2006-04.txt)
  /// for more information.
  case info(Info)

  /// `"option name <x> type <t> ..."`
  ///
  /// Advertises a configurable engine option during UCI initialization.
  case option(Option)

  /// `"copyprotection <status>"`
  case copyProtection(CopyProtection)

  /// `"registration <status>"`
  case registration(Registration)

  /// Any non-empty response that is not currently modeled by this package.
  case unknown(String)

}

extension EngineResponse: Equatable {}

extension EngineResponse: RawRepresentable {
  public init?(rawValue: String) {
    let parsed = EngineResponseParser.parse(response: rawValue)

    guard let parsed else {
      return nil
    }

    self = parsed
  }

  public var rawValue: String {
    switch self {
    case let .id(id):
      switch id {
      case let .name(name):
        "<id> <name> \(name)"
      case let .author(author):
        "<id> <author> \(author)"
      }
    case .uciok:
      "<uciok>"
    case .readyok:
      "<readyok>"
    case let .bestmove(move, ponder):
      if let ponder {
        "<bestmove> \(move) <ponder> \(ponder)"
      } else {
        "<bestmove> \(move)"
      }
    case let .info(info):
      "<info>\(info)"
    case let .option(option):
      "<option> \(option)"
    case let .copyProtection(status):
      "<copyprotection> \(status.rawValue)"
    case let .registration(status):
      "<registration> \(status.rawValue)"
    case let .unknown(rawValue):
      rawValue
    }
  }
}

public extension EngineResponse {
  struct Option: Equatable, Sendable, CustomStringConvertible {
    public var name: String
    public var type: OptionType
    public var defaultValue: String?
    public var min: Int?
    public var max: Int?
    public var vars: [String]

    public init(
      name: String,
      type: OptionType,
      defaultValue: String? = nil,
      min: Int? = nil,
      max: Int? = nil,
      vars: [String] = []
    ) {
      self.name = name
      self.type = type
      self.defaultValue = defaultValue
      self.min = min
      self.max = max
      self.vars = vars
    }

    public var description: String {
      var result = "name \(name) type \(type.rawValue)"

      if let defaultValue {
        result += " default \(defaultValue)"
      }

      if let min {
        result += " min \(min)"
      }

      if let max {
        result += " max \(max)"
      }

      for value in vars {
        result += " var \(value)"
      }

      return result
    }
  }

  enum OptionType: String, Equatable, Sendable {
    case check
    case spin
    case combo
    case button
    case string
    case unknown
  }

  enum CopyProtection: String, Equatable, Sendable {
    case checking
    case ok
    case error
    case unknown
  }

  enum Registration: String, Equatable, Sendable {
    case checking
    case ok
    case error
    case unknown
  }
}
