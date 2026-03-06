//
//  SolanaWalletService.swift
//  Crypto miner
//
//  Stores Solana keypair in Keychain for fully automatic DEX swaps.
//

import Foundation
import Combine
import SolanaSwift
import Security

@MainActor
class SolanaWalletService: ObservableObject {
    @Published var isConnected = false
    @Published var publicKey: String?
    @Published var errorMessage: String?
    
    private let keychainKey = "com.cryptominer.solana.keypair"
    
    var hasWallet: Bool { publicKey != nil }
    
    init() {
        loadFromKeychain()
    }
    
    /// Import from secret key (base58 string, e.g. from Phantom export)
    func importFromPrivateKey(_ base58: String) throws {
        errorMessage = nil
        let decoded = try Base58.decode(base58)
        let keyPair = try KeyPair(secretKey: Data(decoded))
        try saveToKeychain(keyPair)
        publicKey = keyPair.publicKey.base58EncodedString
        isConnected = true
    }
    
    /// Import from seed phrase (12 or 24 words)
    func importFromSeedPhrase(_ words: [String]) async throws {
        errorMessage = nil
        let keyPair = try await KeyPair(phrase: words, network: .mainnetBeta, derivablePath: .default)
        try saveToKeychain(keyPair)
        publicKey = keyPair.publicKey.base58EncodedString
        isConnected = true
    }
    
    /// Get KeyPair for signing. Returns nil if not connected.
    func getKeyPair() throws -> KeyPair? {
        guard let data = KeychainHelper.load(key: keychainKey) else { return nil }
        return try KeyPair(secretKey: data)
    }
    
    func disconnect() {
        KeychainHelper.delete(key: keychainKey)
        publicKey = nil
        isConnected = false
    }
    
    private func loadFromKeychain() {
        guard let data = KeychainHelper.load(key: keychainKey),
              let keyPair = try? KeyPair(secretKey: data) else {
            return
        }
        publicKey = keyPair.publicKey.base58EncodedString
        isConnected = true
    }
    
    private func saveToKeychain(_ keyPair: KeyPair) throws {
        KeychainHelper.save(key: keychainKey, data: keyPair.secretKey)
    }
}

// MARK: - Keychain Helper
enum KeychainHelper {
    static func save(key: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary) // Remove existing
        SecItemAdd(query as CFDictionary, nil)
    }
    
    static func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? (result as? Data) : nil
    }
    
    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Base58 (minimal for Solana)
enum Base58 {
    private static let alphabet = [Character]("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    
    static func decode(_ string: String) throws -> [UInt8] {
        var result = [UInt8]()
        var leadingOnes = 0
        for char in string {
            if char == "1" { leadingOnes += 1 } else { break }
        }
        for char in string.dropFirst(leadingOnes) {
            guard let index = alphabet.firstIndex(of: char) else {
                throw Base58Error.invalidCharacter
            }
            var carry = alphabet.distance(from: alphabet.startIndex, to: index)
            for j in (0..<result.count).reversed() {
                carry += 58 * Int(result[j])
                result[j] = UInt8(carry % 256)
                carry /= 256
            }
            while carry > 0 {
                result.insert(UInt8(carry % 256), at: 0)
                carry /= 256
            }
        }
        result = [UInt8](repeating: 0, count: leadingOnes) + result
        return result
    }
}

enum Base58Error: LocalizedError {
    case invalidCharacter
    var errorDescription: String? { "Invalid Base58 character" }
}
