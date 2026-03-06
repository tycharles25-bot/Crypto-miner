//
//  AutoTradeService.swift
//  Crypto miner
//
//  Auto-buys pumps on Coinbase when detected. User sets per-trade amount and total budget.
//

import Foundation
import Combine

@MainActor
class AutoTradeService: ObservableObject {
    @Published var isEnabled = false
    @Published var perTradeAmount: Double = 10.0
    @Published var totalBudget: Double = 100.0
    @Published var spentSoFar: Double = 0
    @Published var lastTrade: String?
    @Published var errorMessage: String?
    @Published var tradeCount = 0
    
    private let coinbaseService: CoinbaseAccountService
    private var products: [String: String] = [:]  // base symbol -> product_id
    private var tradedSymbols = Set<String>()
    private let cooldownMinutes = 30  // Don't re-buy same symbol within 30 min
    
    init(coinbaseService: CoinbaseAccountService) {
        self.coinbaseService = coinbaseService
    }
    
    var remainingBudget: Double {
        max(0, totalBudget - spentSoFar)
    }
    
    func loadProducts() async {
        guard coinbaseService.isConnected else { return }
        do {
            let list = try await coinbaseService.fetchProducts()
            products = [:]
            for p in list {
                let base = p.base_currency.uppercased()
                if p.quote_currency == "USDT" || p.quote_currency == "USD" {
                    products[base] = p.id
                }
            }
        } catch {
            errorMessage = "Could not load products: \(error.localizedDescription)"
        }
    }
    
    func tryTrade(pump: PumpAlert) async {
        guard isEnabled else { return }
        guard coinbaseService.isConnected else { return }
        guard remainingBudget >= perTradeAmount else { return }
        
        let base = pump.displaySymbol.uppercased()
        guard !base.isEmpty else { return }
        
        // Cooldown: don't buy same symbol again within 30 min
        if tradedSymbols.contains(base) { return }
        
        guard let productId = products[base] else {
            // Symbol not on Coinbase - skip
            return
        }
        
        do {
            try await coinbaseService.placeMarketBuy(productId: productId, funds: perTradeAmount)
            spentSoFar += perTradeAmount
            tradedSymbols.insert(base)
            tradeCount += 1
            lastTrade = "Bought \(base) at +\(Int(pump.priceChangePercent))%"
            errorMessage = nil
            Task { await coinbaseService.refreshBalance() }
        } catch {
            errorMessage = "Trade failed: \(error.localizedDescription)"
        }
    }
    
    func resetBudget() {
        spentSoFar = 0
        tradedSymbols.removeAll()
    }
}
