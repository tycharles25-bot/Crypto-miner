//
//  PumpAlert.swift
//  Crypto miner
//

import Foundation

/// Detected pump or outlier
struct PumpAlert: Identifiable {
    let id: String
    let symbol: String
    let priceChangePercent: Double
    let price: Double
    let volume: Double
    let quoteVolume: Double
    let detectedAt: Date
    /// Chain/network for DEX (e.g. solana, base). nil = CEX (Binance).
    let network: String?
    /// Base token mint/address for DEX swap URLs (e.g. Jupiter). nil for CEX.
    let baseTokenMint: String?
    
    init(id: String, symbol: String, priceChangePercent: Double, price: Double, volume: Double, quoteVolume: Double, detectedAt: Date, network: String? = nil, baseTokenMint: String? = nil) {
        self.id = id
        self.symbol = symbol
        self.priceChangePercent = priceChangePercent
        self.price = price
        self.volume = volume
        self.quoteVolume = quoteVolume
        self.detectedAt = detectedAt
        self.network = network
        self.baseTokenMint = baseTokenMint
    }
    
    var severity: PumpSeverity {
        switch priceChangePercent {
        case 1000...: return .extreme
        case 500..<1000: return .massive
        case 200..<500: return .major
        case 100..<200: return .significant
        case 50..<100: return .moderate
        default: return .minor
        }
    }
    
    var displaySymbol: String {
        symbol.replacingOccurrences(of: "USDT", with: "")
    }
    
    /// True if from DEX (GeckoTerminal). Not tradeable on Coinbase.
    var isDEX: Bool { network != nil }
}

enum PumpSeverity: String {
    case minor = "Minor"
    case moderate = "Moderate"
    case significant = "Significant"
    case major = "Major"
    case massive = "Massive"
    case extreme = "Extreme"
}
