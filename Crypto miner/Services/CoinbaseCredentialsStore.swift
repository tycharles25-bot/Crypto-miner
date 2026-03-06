//
//  CoinbaseCredentialsStore.swift
//  Crypto miner
//

import Foundation
import Security

enum CoinbaseCredentialsStore {
    private static let service = "com.cryptominer.coinbase"
    private static let apiKeyAccount = "api_key"
    private static let secretKeyAccount = "secret_key"
    private static let passphraseAccount = "passphrase"
    
    static func save(apiKey: String, secretKey: String, passphrase: String) {
        _ = saveToKeychain(account: apiKeyAccount, value: apiKey)
        _ = saveToKeychain(account: secretKeyAccount, value: secretKey)
        _ = saveToKeychain(account: passphraseAccount, value: passphrase)
    }
    
    static func load() -> (apiKey: String, secretKey: String, passphrase: String)? {
        guard let apiKey = loadFromKeychain(account: apiKeyAccount),
              let secretKey = loadFromKeychain(account: secretKeyAccount),
              let passphrase = loadFromKeychain(account: passphraseAccount),
              !apiKey.isEmpty, !secretKey.isEmpty, !passphrase.isEmpty else {
            return nil
        }
        return (apiKey, secretKey, passphrase)
    }
    
    static func clear() {
        deleteFromKeychain(account: apiKeyAccount)
        deleteFromKeychain(account: secretKeyAccount)
        deleteFromKeychain(account: passphraseAccount)
    }
    
    static func hasCredentials() -> Bool {
        load() != nil
    }
    
    private static func saveToKeychain(account: String, value: String) -> Bool {
        deleteFromKeychain(account: account)
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
    
    private static func loadFromKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }
    
    private static func deleteFromKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
