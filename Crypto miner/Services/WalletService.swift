//
//  WalletService.swift
//  Crypto miner
//

import Foundation
import Combine

@MainActor
class WalletService: ObservableObject {
    @Published var wallet: Wallet
    
    private let storageKey = "wallet_data"
    
    init() {
        self.wallet = WalletService.load()
    }
    
    var balance: Double { wallet.balance }
    var totalDeposited: Double { wallet.totalDeposited }
    var totalWithdrawn: Double { wallet.totalWithdrawn }
    var totalProfit: Double { wallet.totalProfit }
    var transactions: [WalletTransaction] { wallet.transactions }
    
    func deposit(amount: Double, note: String? = nil) {
        guard amount > 0 else { return }
        
        let tx = WalletTransaction(
            id: UUID(),
            type: .deposit,
            amount: amount,
            currency: "USD",
            note: note,
            date: Date()
        )
        wallet.transactions.insert(tx, at: 0)
        wallet.balance += amount
        wallet.totalDeposited += amount
        wallet.transactions = Array(wallet.transactions.prefix(100))
        save()
    }
    
    func withdraw(amount: Double, note: String? = nil) -> Bool {
        guard amount > 0, amount <= wallet.balance else { return false }
        
        let tx = WalletTransaction(
            id: UUID(),
            type: .withdrawal,
            amount: amount,
            currency: "USD",
            note: note,
            date: Date()
        )
        wallet.transactions.insert(tx, at: 0)
        wallet.balance -= amount
        wallet.totalWithdrawn += amount
        wallet.transactions = Array(wallet.transactions.prefix(100))
        save()
        return true
    }
    
    func recordProfit(amount: Double, note: String? = nil) {
        guard amount > 0 else { return }
        
        let tx = WalletTransaction(
            id: UUID(),
            type: .profit,
            amount: amount,
            currency: "USD",
            note: note,
            date: Date()
        )
        wallet.transactions.insert(tx, at: 0)
        wallet.balance += amount
        wallet.totalProfit += amount
        wallet.transactions = Array(wallet.transactions.prefix(100))
        save()
    }
    
    func recordLoss(amount: Double, note: String? = nil) {
        guard amount > 0, amount <= wallet.balance else { return }
        
        let tx = WalletTransaction(
            id: UUID(),
            type: .loss,
            amount: amount,
            currency: "USD",
            note: note,
            date: Date()
        )
        wallet.transactions.insert(tx, at: 0)
        wallet.balance -= amount
        wallet.totalProfit -= amount
        wallet.transactions = Array(wallet.transactions.prefix(100))
        save()
    }
    
    private func save() {
        WalletService.save(wallet)
    }
    
    private static func load() -> Wallet {
        guard let data = UserDefaults.standard.data(forKey: "wallet_data"),
              let decoded = try? JSONDecoder().decode(Wallet.self, from: data) else {
            return Wallet()
        }
        return decoded
    }
    
    private static func save(_ wallet: Wallet) {
        guard let data = try? JSONEncoder().encode(wallet) else { return }
        UserDefaults.standard.set(data, forKey: "wallet_data")
    }
}
