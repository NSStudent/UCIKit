//
//  EngineCommand.swift
//  UCIKit
//

/// Possible engine commands based on the
/// [Universal Chess Interface (UCI)](https://backscattering.de/chess/uci/2006-04.txt).
public enum EngineCommand: Equatable, Sendable {

  /// `"debug [ on | off ]"`
  ///
  /// Switches the engine's debug mode on or off.
  ///
  /// According to UCI, debug mode should make the engine emit additional
  /// diagnostic information, typically via `info string ...`, and this
  /// command may be sent at any time, even while the engine is thinking.
  case debug(on: Bool)

  /// `"uci"`
  ///
  /// Requests that the engine enter UCI mode.
  ///
  /// This is the first command that should be sent after boot. Once received,
  /// the engine is expected to identify itself with `id ...`, advertise any
  /// supported options, and finally answer with `uciok`.
  case uci

  /// `"isready"`
  ///
  /// Synchronizes with the engine and checks that it is ready.
  ///
  /// UCI requires the engine to respond with `readyok`. This can be used
  /// after potentially expensive setup commands and may also be sent while
  /// the engine is calculating.
  case isready

  /// `"setoption name <id> [value <x>]"`
  ///
  /// Updates an engine option exposed through UCI.
  ///
  /// For button-style options no value is required. UCI also allows option
  /// names and values to contain spaces, though the substrings `"name"` and
  /// `"value"` should be avoided inside them to keep parsing unambiguous.
  case setoption(id: String, value: String? = nil)

  /// `"ucinewgame"`
  ///
  /// Signals that the next search belongs to a new game.
  ///
  /// This lets the engine discard search state tied to the previous game.
  /// UCI recommends following this command with `isready` because processing
  /// it may take time.
  case ucinewgame

  /// `"position [fen <fenstring> | startpos ]  moves <move1> .... <movei>"`
  ///
  /// Sets the current board position the engine should analyze or play from.
  ///
  /// The base position can be either `startpos` or an explicit FEN string.
  /// Any moves supplied after that are played on top of the base position in
  /// long algebraic notation before a later `go` command starts the search.
  case position(PositionString, moves: [String]? = nil)

  /// `"go [searchmoves ...] [ponder] [wtime <x>] [btime <x>] [winc <x>] [binc <x>] [movestogo <x>] [depth <x>] [nodes <x>] [mate <x>] [movetime <x>] [infinite]"`
  ///
  /// Starts calculating on the current position.
  ///
  /// All parameters map directly to the UCI `go` subcommands and may be
  /// combined in the same line. If a parameter is omitted it should be
  /// interpreted as "does not constrain the search".
  ///
  /// Important UCI semantics:
  /// - `searchmoves` restricts the search to a subset of legal moves.
  /// - `ponder` starts the search in pondering mode.
  /// - `wtime`, `btime`, `winc`, `binc`, and `movestogo` describe the clock.
  /// - `depth`, `nodes`, `mate`, and `movetime` impose search limits.
  /// - `infinite` keeps searching until an explicit `stop`.
  case go(
    searchmoves: [String]? = nil, ponder: Bool = false,
    wtime: Int? = nil, btime: Int? = nil,
    winc: Int? = nil, binc: Int? = nil,
    movestogo: Int? = nil, depth: Int? = nil,
    nodes: Int? = nil, mate: Int? = nil,
    movetime: Int? = nil, infinite: Bool = false
  )

  /// `"stop"`
  ///
  /// Requests that the engine stop searching as soon as possible.
  ///
  /// Under UCI, stopping a search should be followed by a `bestmove`
  /// response from the engine, optionally with a `ponder` move.
  case stop

  /// `"ponderhit"`
  ///
  /// Tells the engine that the user played the move it was pondering on.
  ///
  /// After receiving this command, the engine should continue the ongoing
  /// search but switch from ponder mode to normal search mode.
  case ponderhit

  /// `"quit"`
  ///
  /// Requests that the engine terminate as soon as possible.
  case quit

  /// Produces the raw engine-readable string for the given command.
  var rawValue: String {
    switch self {
    case let .debug(on):
      return "debug \(on ? "on" : "off")"
    case .uci:
      return "uci"
    case .isready:
      return "isready"
    case let .setoption(id, value):
      var result = "setoption name \(id)"

      if let value {
        result += " value \(value)"
      }

      return result
    case .ucinewgame:
      return "ucinewgame"
    case let .position(position, moves):
      var result = "position \(position.rawValue)"

      if let moves, !moves.isEmpty {
        result += " moves \(moves.joined(separator: " "))"
      }

      return result
    case let .go(
      searchmoves, ponder, wtime, btime, winc, binc,
      movestogo, depth, nodes, mate, movetime, infinite
    ):
      var result = "go"

      if ponder {
        result += " ponder"
      }

      if let wtime {
        result += " wtime \(wtime)"
      }

      if let btime {
        result += " btime \(btime)"
      }

      if let winc {
        result += " winc \(winc)"
      }

      if let binc {
        result += " binc \(binc)"
      }

      if let movestogo {
        result += " movestogo \(movestogo)"
      }

      if let depth {
        result += " depth \(depth)"
      }

      if let nodes {
        result += " nodes \(nodes)"
      }

      if let mate {
        result += " mate \(mate)"
      }

      if let movetime {
        result += " movetime \(movetime)"
      }

      if infinite {
        result += " infinite"
      }

      // Stockfish consumes every remaining token as a move after this keyword.
      if let searchmoves, !searchmoves.isEmpty {
        result += " searchmoves \(searchmoves.joined(separator: " "))"
      }

      return result
    case .stop:
      return "stop"
    case .ponderhit:
      return "ponderhit"
    case .quit:
      return "quit"
    }
  }

  static func nextSetupLoopCommand(given response: EngineResponse?) -> EngineCommand? {
    // engine setup loop
    // <uci> → <uciok> → <isready> → <readok> → complete

    switch response {
    case nil:
      return .uci
    case .uciok:
      return .isready
    default:
      return nil
    }
  }
}
