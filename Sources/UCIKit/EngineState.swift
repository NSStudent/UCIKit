//
//  EngineState.swift
//  UCIKit
//

/// Public lifecycle state for an ``Engine`` instance.
public enum EngineState: Equatable, Sendable {
  case idle
  case starting
  case handshaking
  case configuring
  case ready
  case thinking
  case stopping
  case stopped
  case failed(EngineError)
}

