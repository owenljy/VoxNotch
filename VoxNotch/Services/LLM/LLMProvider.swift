//
//  LLMProvider.swift
//  VoxNotch
//
//  Protocol and implementations for LLM text post-processing
//

import Foundation

// MARK: - LLM Provider Protocol

/// Protocol for LLM text processing providers
protocol LLMProvider: Sendable {

  /// Process text through the LLM
  /// - Parameters:
  ///   - text: The text to process
  ///   - prompt: The system/user prompt for processing
  /// - Returns: The processed text
  func process(text: String, prompt: String, language: String?) async throws -> String
}

// MARK: - LLM Errors

enum LLMError: LocalizedError {
  case noAPIKey
  case invalidURL
  case networkError(Error)
  case invalidResponse
  case apiError(String)
  case timeout
  case rateLimited
  case decodingError(Error)

  var errorDescription: String? {
    switch self {
    case .noAPIKey:
      return "API key missing"
    case .invalidURL:
      return "Invalid API endpoint"
    case .networkError:
      return "Network error"
    case .invalidResponse:
      return "Bad response from API"
    case .apiError:
      return "API returned an error"
    case .timeout:
      return "Request timed out"
    case .rateLimited:
      return "Too many requests"
    case .decodingError:
      return "Unexpected API response"
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .noAPIKey:
      return "Add your API key in Settings → Tones"
    case .invalidURL:
      return "Check the endpoint URL in Settings"
    case .networkError, .timeout:
      return "Check your connection and try again"
    case .invalidResponse, .decodingError:
      return "Try again — or switch to a different model"
    case .apiError:
      return "Check your API key and model settings"
    case .rateLimited:
      return "Wait a moment and try again"
    }
  }
}

extension LLMError {
  /// Error text including the server-provided detail, for settings and inline UI.
  nonisolated var detailedDescription: String {
    switch self {
    case .apiError(let message): return message
    case .networkError(let error): return error.localizedDescription
    case .decodingError(let error): return error.localizedDescription
    default: return errorDescription ?? "Unknown error"
    }
  }
}
