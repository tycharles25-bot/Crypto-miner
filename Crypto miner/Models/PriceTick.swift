//
//  PriceTick.swift
//  Crypto miner
//

import Foundation

/// Single price update from exchange
struct PriceTick: Identifiable {
    let id: String
    let symbol: String
    let price: Double
    let priceChangePercent: Double
    let volume: Double
    let quoteVolume: Double
    let timestamp: Date
    
    var displaySymbol: String {
        symbol.replacingOccurrences(of: "USDT", with: "")
    }
}

/// Binance combined stream response (!ticker@arr)
struct BinanceTickerResponse: Decodable {
    let stream: String?
    let data: [BinanceTickerData]?
}

struct BinanceTickerData: Decodable {
    let e: String?      // Event type
    let E: Int64?       // Event time
    let s: String       // Symbol
    let p: String       // Price change
    let P: String       // Price change percent
    let c: String       // Last price
    let Q: String?      // Last quantity
    let v: String       // Total traded base volume
    let q: String       // Total traded quote volume
    let o: String       // Open price
    let h: String       // High price
    let l: String       // Low price
    
    func toPriceTick() -> PriceTick {
        PriceTick(
            id: s + "-\(E ?? 0)",
            symbol: s,
            price: Double(c) ?? 0,
            priceChangePercent: Double(P) ?? 0,
            volume: Double(v) ?? 0,
            quoteVolume: Double(q) ?? 0,
            timestamp: Date()
        )
    }
}
