//
//  JupiterConfig.swift
//  Crypto miner
//
//  Optional API key for Jupiter. Without key: uses lite-api.jup.ag (keyless).
//  With key: uses api.jup.ag for higher rate limits. Get free key at portal.jup.ag
//

import Foundation

enum JupiterConfig {
    private static let apiKeyKey = "jupiter_api_key"

    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: apiKeyKey) }
    }

    static var baseURL: String {
        apiKey.isEmpty ? "https://lite-api.jup.ag" : "https://api.jup.ag"
    }
}
