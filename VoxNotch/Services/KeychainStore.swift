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

  static func string(for account: String) -> String? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
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
