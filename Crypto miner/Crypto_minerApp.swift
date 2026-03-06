//
//  Crypto_minerApp.swift
//  Crypto miner
//

import SwiftUI

@main
struct Crypto_minerApp: App {
    @StateObject private var wallet = WalletService()
    @StateObject private var dexTradeService = DEXTradeService()
    @StateObject private var solanaWallet = SolanaWalletService()
    @StateObject private var jupiterSwap = JupiterSwapService()
    @StateObject private var renderPump = RenderPumpService()
    @StateObject private var solanaBalance = SolanaBalanceService()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(wallet)
                .environmentObject(dexTradeService)
                .environmentObject(solanaWallet)
                .environmentObject(jupiterSwap)
                .environmentObject(renderPump)
                .environmentObject(solanaBalance)
        }
    }
}
