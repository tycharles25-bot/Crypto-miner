//
//  DEXTradeService.swift
//  Crypto miner
//
//  DEX-first trading. Opens swap URLs (Jupiter, Uniswap, etc.) for pump tokens.
//

import Foundation
import SwiftUI
import Combine

struct TradeRecord: Identifiable, Codable {
    let id: UUID
    let symbol: String
    let action: String  // "Buy" or "Sell"
    let date: Date
    let note: String?
    
    init(id: UUID = UUID(), symbol: String, action: String, date: Date = Date(), note: String? = nil) {
        self.id = id
        self.symbol = symbol
        self.action = action
        self.date = date
        self.note = note
    }
}

@MainActor
class DEXTradeService: ObservableObject {
    @Published var isEnabled = false
    @Published var perTradeAmount: Double = 10.0
    @Published var totalBudget: Double = 100.0
    @Published var spentSoFar: Double = 0
    @Published var lastTrade: String?
    @Published var errorMessage: String?
    @Published var tradeCount = 0
    @Published var pendingCashouts: [(pump: PumpAlert, depositAt: Date, cashoutAfterSeconds: TimeInterval)] = []
    @Published var tradeHistory: [TradeRecord] = []
    
    private let tradeHistoryKey = "dex_trade_history"
    
    init() {
        loadTradeHistory()
    }
    
    private func loadTradeHistory() {
        guard let data = UserDefaults.standard.data(forKey: tradeHistoryKey),
              let decoded = try? JSONDecoder().decode([TradeRecord].self, from: data) else { return }
        tradeHistory = Array(decoded.prefix(10))
    }
    
    private func saveTradeHistory() {
        let toSave = Array(tradeHistory.prefix(10))
        guard let data = try? JSONEncoder().encode(toSave) else { return }
        UserDefaults.standard.set(data, forKey: tradeHistoryKey)
    }
    
    private func addTrade(symbol: String, action: String, note: String? = nil) {
        let record = TradeRecord(symbol: symbol, action: action, note: note)
        tradeHistory.insert(record, at: 0)
        tradeHistory = Array(tradeHistory.prefix(10))
        saveTradeHistory()
    }
    
    private var tradedSymbols = Set<String>()
    private let cooldownMinutes = 30
    private var cashoutTasks: [String: Task<Void, Never>] = [:]
    private var isBuyInProgress = false // Only 1 buy at a time
    
    var remainingBudget: Double {
        max(0, totalBudget - spentSoFar)
    }
    
    /// Swap URL for buying (deposit). SOL/ETH -> token.
    /// - Parameter amountLamports: Optional SOL amount for Jupiter pre-fill (?amount=)
    func swapURL(for pump: PumpAlert, amountLamports: UInt64? = nil) -> URL? {
        guard pump.isDEX, let network = pump.network, let mint = pump.baseTokenMint else { return nil }
        
        switch network {
        case "solana":
            let sol = "So11111111111111111111111111111111111111112"
            var url = "https://jup.ag/swap/\(sol)-\(mint)"
            if let amt = amountLamports, amt > 0 { url += "?amount=\(amt)" }
            return URL(string: url)
        case "base":
            return URL(string: "https://app.uniswap.org/swap?outputCurrency=\(mint)&chain=base")
        case "eth":
            return URL(string: "https://app.uniswap.org/swap?outputCurrency=\(mint)&chain=mainnet")
        case "arbitrum":
            return URL(string: "https://app.uniswap.org/swap?outputCurrency=\(mint)&chain=arbitrum")
        case "bsc":
            return URL(string: "https://app.uniswap.org/swap?outputCurrency=\(mint)&chain=bsc")
        case "polygon_pos":
            return URL(string: "https://app.uniswap.org/swap?outputCurrency=\(mint)&chain=polygon")
        case "optimism":
            return URL(string: "https://app.uniswap.org/swap?outputCurrency=\(mint)&chain=optimism")
        default:
            // Fallback: GeckoTerminal pool page
            let poolAddr = pump.id.split(separator: "_", maxSplits: 1).last.map(String.init) ?? pump.id
            return URL(string: "https://www.geckoterminal.com/\(network)/pools/\(poolAddr)")
        }
    }
    
    /// Sell URL for cashing out after 1 hour. Token -> SOL/ETH.
    func sellURL(for pump: PumpAlert) -> URL? {
        guard pump.isDEX, let network = pump.network, let mint = pump.baseTokenMint else { return nil }
        
        switch network {
        case "solana":
            let sol = "So11111111111111111111111111111111111111112"
            return URL(string: "https://jup.ag/swap/\(mint)-\(sol)")
        case "base":
            return URL(string: "https://app.uniswap.org/swap?inputCurrency=\(mint)&chain=base")
        case "eth":
            return URL(string: "https://app.uniswap.org/swap?inputCurrency=\(mint)&chain=mainnet")
        case "arbitrum":
            return URL(string: "https://app.uniswap.org/swap?inputCurrency=\(mint)&chain=arbitrum")
        case "bsc":
            return URL(string: "https://app.uniswap.org/swap?inputCurrency=\(mint)&chain=bsc")
        case "polygon_pos":
            return URL(string: "https://app.uniswap.org/swap?inputCurrency=\(mint)&chain=polygon")
        case "optimism":
            return URL(string: "https://app.uniswap.org/swap?inputCurrency=\(mint)&chain=optimism")
        default:
            let poolAddr = pump.id.split(separator: "_", maxSplits: 1).last.map(String.init) ?? pump.id
            return URL(string: "https://www.geckoterminal.com/\(network)/pools/\(poolAddr)")
        }
    }
    
    /// SOL per trade for automatic Solana swaps (lamports). 0.01 SOL = 10_000_000
    @Published var solPerTradeLamports: UInt64 = 10_000_000
    
    /// Try to open swap for pump. For Solana + connected wallet: executes swap automatically. Else opens URL.
    /// - Parameter cashoutAfterSeconds: When to open sell URL or execute sell (e.g. 3600 = 1h). nil = no auto cashout.
    func tryTrade(
        pump: PumpAlert,
        cashoutAfterSeconds: TimeInterval? = nil,
        solanaWallet: SolanaWalletService? = nil,
        solanaBalance: SolanaBalanceService? = nil,
        jupiterSwap: JupiterSwapService? = nil
    ) {
        guard isEnabled else { return }
        guard pump.isDEX else { return }
        guard !isBuyInProgress else { return } // Only 1 buy at a time
        
        let key = (pump.baseTokenMint ?? pump.displaySymbol) + "-" + (pump.network ?? "")
        if tradedSymbols.contains(key) { return }
        
        // 80% of wallet per trade, 20% left for fees. Min 0.003 SOL total.
        let minBalanceLamports: UInt64 = 3_000_000 // 0.003 SOL
        guard let bal = solanaBalance?.balanceLamports, bal >= minBalanceLamports else {
            errorMessage = "Insufficient SOL. Need at least 0.003 SOL (balance: \(String(format: "%.4f", Double(solanaBalance?.balanceLamports ?? 0) / 1_000_000_000)))."
            return
        }
        let useAutoSwap = pump.network == "solana" && solanaWallet?.hasWallet == true && jupiterSwap != nil
        
        if useAutoSwap, let wallet = solanaWallet, let jupiter = jupiterSwap, let mint = pump.baseTokenMint {
            isBuyInProgress = true
            Task { @MainActor in
                defer { isBuyInProgress = false }
                // Re-fetch balance right before buy (may have changed)
                if let pub = solanaWallet.publicKey {
                    await solanaBalance?.fetchBalance(publicKey: pub)
                }
                let currentBal = solanaBalance?.balanceLamports ?? 0
                let amountToUse = currentBal >= minBalanceLamports ? UInt64(Double(currentBal) * 0.8) : 0
                guard amountToUse >= 1_000_000 else {
                    errorMessage = "Insufficient SOL for trade."
                    return
                }
                do {
                    let sig = try await jupiter.executeBuy(
                        outputMint: mint,
                        solAmountLamports: amountToUse,
                        walletService: wallet,
                        slippageBps: 1000,
                        balanceLamports: solanaBalance?.balanceLamports
                    )
                    spentSoFar += Double(amountToUse) / 1_000_000_000
                    tradedSymbols.insert(key)
                    tradeCount += 1
                    addTrade(symbol: pump.baseTokenMint.map { "\($0.prefix(6))...\($0.suffix(4))" } ?? pump.displaySymbol, action: "Buy", note: "tx: \(String(sig.prefix(8)))...")
                    lastTrade = "Bought \(pump.displaySymbol) (+\(Int(pump.priceChangePercent))%) tx: \(String(sig.prefix(8)))..."
                    errorMessage = nil
                    if let secs = cashoutAfterSeconds, secs > 0 {
                        let depositAt = Date()
                        pendingCashouts.append((pump, depositAt, secs))
                        scheduleCashout(pump: pump, depositAt: depositAt, cashoutAfterSeconds: secs, jupiterSwap: jupiter, solanaWallet: wallet)
                    }
                } catch {
                    errorMessage = error.localizedDescription
                    lastTrade = nil
                    let isNoRoute = error.localizedDescription.lowercased().contains("no route")
                    if isNoRoute {
                        // Delayed retry: Jupiter may index token in ~45 sec
                        try? await Task.sleep(nanoseconds: 45_000_000_000)
                        if let pub = solanaWallet.publicKey {
                            await solanaBalance?.fetchBalance(publicKey: pub)
                        }
                        let retryBal = solanaBalance?.balanceLamports ?? 0
                        let retryAmount = retryBal >= minBalanceLamports ? UInt64(Double(retryBal) * 0.8) : 0
                        guard retryAmount >= 1_000_000 else {
                            tradedSymbols.insert(key)
                            addTrade(symbol: pump.baseTokenMint.map { "\($0.prefix(6))...\($0.suffix(4))" } ?? pump.displaySymbol, action: "Buy failed", note: "Insufficient SOL after retry")
                            return
                        }
                        do {
                            let sig = try await jupiter.executeBuy(
                                outputMint: mint,
                                solAmountLamports: retryAmount,
                                walletService: wallet,
                                slippageBps: 1000,
                                balanceLamports: solanaBalance?.balanceLamports
                            )
                            spentSoFar += Double(retryAmount) / 1_000_000_000
                            tradedSymbols.insert(key)
                            tradeCount += 1
                            addTrade(symbol: pump.baseTokenMint.map { "\($0.prefix(6))...\($0.suffix(4))" } ?? pump.displaySymbol, action: "Buy", note: "tx: \(String(sig.prefix(8)))... (retry)")
                            lastTrade = "Bought \(pump.displaySymbol) (+\(Int(pump.priceChangePercent))%) tx: \(String(sig.prefix(8)))..."
                            errorMessage = nil
                            if let secs = cashoutAfterSeconds, secs > 0 {
                                let depositAt = Date()
                                pendingCashouts.append((pump, depositAt, secs))
                                scheduleCashout(pump: pump, depositAt: depositAt, cashoutAfterSeconds: secs, jupiterSwap: jupiter, solanaWallet: wallet)
                            }
                        } catch {
                            tradedSymbols.insert(key)
                            addTrade(symbol: pump.baseTokenMint.map { "\($0.prefix(6))...\($0.suffix(4))" } ?? pump.displaySymbol, action: "Buy failed", note: error.localizedDescription)
                        }
                    } else {
                        addTrade(symbol: pump.baseTokenMint.map { "\($0.prefix(6))...\($0.suffix(4))" } ?? pump.displaySymbol, action: "Buy failed", note: error.localizedDescription)
                    }
                }
            }
            return
        }
        
        // No wallet imported — open Jupiter only, do NOT record as traded
        guard let url = swapURL(for: pump) else { return }
        UIApplication.shared.open(url)
        addTrade(symbol: pump.baseTokenMint.map { "\($0.prefix(6))...\($0.suffix(4))" } ?? pump.displaySymbol, action: "Buy failed", note: "No wallet imported")
        lastTrade = "Opened \(pump.displaySymbol) — import a wallet in Settings for automatic trades"
        errorMessage = "Import a Solana wallet in Settings for fully automatic swaps."
    }
    
    private func scheduleCashout(
        pump: PumpAlert,
        depositAt: Date,
        cashoutAfterSeconds: TimeInterval,
        jupiterSwap: JupiterSwapService? = nil,
        solanaWallet: SolanaWalletService? = nil
    ) {
        let pumpId = pump.id
        let mint = pump.baseTokenMint
        let useAutoSell = pump.network == "solana" && mint != nil && solanaWallet?.hasWallet == true && jupiterSwap != nil
        let downturnEnabled = DownturnConfig.isEnabled && useAutoSell && jupiterSwap != nil
        
        let task = Task { @MainActor in
            if downturnEnabled, let jupiter = jupiterSwap, let wallet = solanaWallet, let tokenMint = mint {
                // Combined loop: check timer + downturn every 5 sec
                let pollInterval: UInt64 = 5_000_000_000 // 5 sec
                var peakPrice: Double?
                // Wait 15 sec after buy before first price check (let price stabilize)
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                while !Task.isCancelled {
                    let elapsed = Date().timeIntervalSince(depositAt)
                    if elapsed >= cashoutAfterSeconds {
                        await performSell(pump: pump, pumpId: pumpId, mint: tokenMint, reason: "timer", jupiterSwap: jupiter, solanaWallet: wallet)
                        break
                    }
                    if let price = await jupiter.fetchPrice(mint: tokenMint), price > 0 {
                        if let peak = peakPrice {
                            let newPeak = max(peak, price)
                            peakPrice = newPeak
                            let threshold = 1.0 - Double(DownturnConfig.percentFromPeak) / 100.0
                            if price < newPeak * threshold {
                                await performSell(pump: pump, pumpId: pumpId, mint: tokenMint, reason: "downturn", jupiterSwap: jupiter, solanaWallet: wallet)
                                break
                            }
                        } else {
                            peakPrice = price
                        }
                    }
                    try? await Task.sleep(nanoseconds: pollInterval)
                }
            } else {
                // Timer only
                try? await Task.sleep(nanoseconds: UInt64(cashoutAfterSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if useAutoSell, let jupiter = jupiterSwap, let wallet = solanaWallet, let tokenMint = mint {
                    await performSell(pump: pump, pumpId: pumpId, mint: tokenMint, reason: "timer", jupiterSwap: jupiter, solanaWallet: wallet)
                } else if let url = sellURL(for: pump) {
                    _ = await UIApplication.shared.open(url)
                    addTrade(symbol: pump.displaySymbol, action: "Sell failed", note: "Opened cashout — complete in browser")
                    lastTrade = "Opened cashout for \(pump.displaySymbol)"
                }
            }
            pendingCashouts.removeAll { $0.pump.id == pumpId }
            cashoutTasks.removeValue(forKey: pumpId)
        }
        cashoutTasks[pumpId] = task
    }
    
    private func performSell(
        pump: PumpAlert,
        pumpId: String,
        mint: String,
        reason: String,
        jupiterSwap: JupiterSwapService,
        solanaWallet: SolanaWalletService
    ) async {
        do {
            let sig = try await jupiterSwap.executeSellAll(
                inputMint: mint,
                walletService: solanaWallet,
                slippageBps: 1000
            )
            addTrade(symbol: pump.displaySymbol, action: "Sell", note: "tx: \(String(sig.prefix(8)))... (\(reason))")
            lastTrade = "Sold \(pump.displaySymbol) (\(reason)) tx: \(String(sig.prefix(8)))..."
        } catch {
            if let url = sellURL(for: pump) {
                _ = await UIApplication.shared.open(url)
                addTrade(symbol: pump.displaySymbol, action: "Sell failed", note: "Opened cashout — complete in browser")
                lastTrade = "Opened cashout for \(pump.displaySymbol) (\(reason) triggered)"
            }
        }
    }
    
    func resetBudget() {
        spentSoFar = 0
        tradedSymbols.removeAll()
    }
}
