//
//  EngineOutput.swift
//  UCIKit
//

/// A raw engine output line paired with the parsed response, when available.
public struct EngineOutput: Equatable, Sendable {
  public var rawValue: String
  public var response: EngineResponse?

  public init(rawValue: String, response: EngineResponse?) {
    self.rawValue = rawValue
    self.response = response
  }
}

