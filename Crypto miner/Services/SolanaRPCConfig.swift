//
//  SolanaRPCConfig.swift
//  Crypto miner
//
//  Optional custom RPC. Public RPC is rate-limited; Helius/QuickNode free tiers are more reliable.
//  Get free key: helius.dev or quicknode.com
//

import Foundation

enum SolanaRPCConfig {
    private static let rpcURLKey = "solana_rpc_url"

    static var rpcURL: String {
        get {
            let stored = UserDefaults.standard.string(forKey: rpcURLKey) ?? ""
            return stored.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: rpcURLKey) }
    }

    static var effectiveRPC: String {
        rpcURL.isEmpty ? "https://api.mainnet-beta.solana.com" : rpcURL
    }
}
