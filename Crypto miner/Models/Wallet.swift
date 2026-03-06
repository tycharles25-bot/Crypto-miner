//
//  Wallet.swift
//  Crypto miner
//

import Foundation

/// Wallet transaction
struct WalletTransaction: Identifiable, Codable {
    let id: UUID
    let type: TransactionType
    let amount: Double
    let currency: String
    let note: String?
    let date: Date
    
    enum TransactionType: String, Codable, CaseIterable {
        case deposit
        case withdrawal
        case profit
        case loss
    }
}

/// Wallet state - balance and history
struct Wallet: Codable {
    var balance: Double
    var totalDeposited: Double
    var totalWithdrawn: Double
    var totalProfit: Double
    var transactions: [WalletTransaction]
    
    init() {
        self.balance = 0
        self.totalDeposited = 0
        self.totalWithdrawn = 0
        self.totalProfit = 0
        self.transactions = []
    }
}
