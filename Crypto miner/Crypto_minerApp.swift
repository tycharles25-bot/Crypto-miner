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
    @State private var solanaBalance = SolanaBalanceService()
    @StateObject private var jupiterSwap = JupiterSwapService()
    @StateObject private var renderPump = RenderPumpService()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(wallet)
                .environmentObject(dexTradeService)
                .environmentObject(solanaWallet)
                .environment(solanaBalance)
                .environmentObject(jupiterSwap)
                .environmentObject(renderPump)
        }
    }
}
