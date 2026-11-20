//
//  EngineError.swift
//  UCIKit
//

import Foundation

/// Errors surfaced by ``Engine`` operations and diagnostic events.
public enum EngineError: Error, Equatable, Sendable {
  case standardIOBusy
  case systemCall(operation: String, code: Int32)
  case engineExitedUnexpectedly
  case nativeFailure(String)
  case startTimeout
  case notReady
  case busy
  case invalidInput(String)
  case unsupportedOption(String)
  case invalidOption(String)
  case shutdownTimeout
  case bufferOverflow
  case resourceLimitExceeded
  case missingResource(URL)
  case invalidResource(URL)
}

extension EngineError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .standardIOBusy:
      return "Another embedded engine owns the C++ stream transport."
    case let .systemCall(operation, code):
      if let posixCode = POSIXErrorCode(rawValue: code) {
        return "\(operation) failed with \(posixCode)."
      } else {
        return "\(operation) failed with errno \(code)."
      }
    case .engineExitedUnexpectedly:
      return "The embedded engine exited unexpectedly."
    case let .nativeFailure(message):
      return "The embedded engine failed: \(message)"
    case .startTimeout:
      return "The engine did not become ready before the timeout expired."
    case .notReady:
      return "Engine is not ready to receive this command."
    case .busy:
      return "An engine operation or search is already in progress."
    case let .invalidInput(reason):
      return "Invalid engine input: \(reason)"
    case let .unsupportedOption(name):
      return "The engine does not advertise option \(name)."
    case let .invalidOption(reason):
      return "Invalid engine option: \(reason)"
    case .shutdownTimeout:
      return "The engine did not stop before the timeout. Its resources remain reserved until it exits."
    case .bufferOverflow:
      return "An engine observation buffer overflowed."
    case .resourceLimitExceeded:
      return "The engine resource exceeds its configured size limit."
    case let .missingResource(url):
      return "Required engine resource does not exist: \(url.path())."
    case let .invalidResource(url):
      return "Engine resource is not readable: \(url.path())."
    }
  }
}

extension EngineError: LocalizedError {
  public var errorDescription: String? { description }
}
