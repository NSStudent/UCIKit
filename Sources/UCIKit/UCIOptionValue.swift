/// Typed value for an option advertised during the UCI handshake.
public enum UCIOptionValue: Equatable, Sendable {
  case check(Bool)
  case spin(Int)
  case combo(String)
  case string(String)
  case button

  var rawValue: String? {
    switch self {
    case .check(let value): return value ? "true" : "false"
    case .spin(let value): return String(value)
    case .combo(let value), .string(let value): return value
    case .button: return nil
    }
  }
}
