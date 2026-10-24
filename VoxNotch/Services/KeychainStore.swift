//
//  KeychainStore.swift
//  VoxNotch
//
//  Minimal generic-password Keychain wrapper for secrets such as API keys.
//

import Foundation
import Security

enum KeychainStore {

  private static let service = "com.voxnotch"

  nonisolated enum ReadResult: Equatable {
    case value(String)
    case notFound
    /// The item exists but macOS wants the user to approve access (e.g. after
    /// an update changed the app's signature).
    case needsApproval
  }

  /// With `interactive: false` this never shows a macOS dialog. Only the legacy
  /// interaction switch suppresses the keychain ACL prompt; kSecUseAuthenticationUIFail
  /// does not (verified on macOS 27). The switch is process-wide, so it is restored
  /// immediately after the read.
  static func read(_ account: String, interactive: Bool) -> ReadResult {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    if !interactive {
      SecKeychainSetUserInteractionAllowed(false)
    }
    defer { if !interactive { SecKeychainSetUserInteractionAllowed(true) } }

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return .notFound }
      return .value(value)
    case errSecItemNotFound:
      return .notFound
    default:
      return .needsApproval
    }
  }

  /// Stores `value`, or deletes the item when `value` is empty.
  @discardableResult
  static func set(_ value: String, for account: String) -> Bool {
    let query = baseQuery(account: account)
    guard !value.isEmpty else {
      let status = SecItemDelete(query as CFDictionary)
      return status == errSecSuccess || status == errSecItemNotFound
    }

    let data = Data(value.utf8)
    let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updateStatus == errSecSuccess { return true }
    guard updateStatus == errSecItemNotFound else { return false }

    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
  }

  private static func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
