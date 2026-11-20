//
//  EngineAnalysis.swift
//  UCIKit
//

import Foundation

/// Search limit used by the high-level analysis API.
public enum AnalysisLimit: Equatable, Sendable {
  case depth(Int)
  case nodes(Int)
  case moveTime(milliseconds: Int)
  case infinite

  var commandArguments: EngineCommand {
    switch self {
    case let .depth(depth):
      return .go(depth: depth)
    case let .nodes(nodes):
      return .go(nodes: nodes)
    case let .moveTime(milliseconds):
      return .go(movetime: milliseconds)
    case .infinite:
      return .go(infinite: true)
    }
  }
}

/// Request for analyzing a chess position with an engine.
public struct AnalysisRequest: Equatable, Sendable {
  public var position: EngineCommand.PositionString
  public var moves: [String]
  public var limit: AnalysisLimit
  public var multipv: Int
  public var startsEngineIfNeeded: Bool
  public var includeWDL: Bool
  public var searchMoves: [String]
  /// Readiness deadline when this request starts an engine automatically.
  public var startupTimeout: Duration

  public init(
    position: EngineCommand.PositionString,
    moves: [String] = [],
    limit: AnalysisLimit = .depth(15),
    multipv: Int = 1,
    startsEngineIfNeeded: Bool = true,
    includeWDL: Bool = false,
    searchMoves: [String] = [],
    startupTimeout: Duration = .seconds(30)
  ) {
    self.position = position
    self.moves = moves
    self.limit = limit
    self.multipv = multipv
    self.startsEngineIfNeeded = startsEngineIfNeeded
    self.includeWDL = includeWDL
    self.searchMoves = searchMoves
    self.startupTimeout = startupTimeout
  }
}

/// Structured update emitted while an analysis is running.
public struct AnalysisUpdate: Equatable, Sendable {
  public var depth: Int?
  public var multipv: Int?
  public var score: EngineResponse.Info.Score?
  public var principalVariation: [String]
  public var nodes: Int?
  public var nps: Int?
  public var bestMove: String?
  public var ponder: String?
  public var wdl: EngineResponse.Info.WDL?

  public init(
    depth: Int? = nil,
    multipv: Int? = nil,
    score: EngineResponse.Info.Score? = nil,
    principalVariation: [String] = [],
    nodes: Int? = nil,
    nps: Int? = nil,
    bestMove: String? = nil,
    ponder: String? = nil,
    wdl: EngineResponse.Info.WDL? = nil
  ) {
    self.depth = depth
    self.multipv = multipv
    self.score = score
    self.principalVariation = principalVariation
    self.nodes = nodes
    self.nps = nps
    self.bestMove = bestMove
    self.ponder = ponder
    self.wdl = wdl
  }
}
