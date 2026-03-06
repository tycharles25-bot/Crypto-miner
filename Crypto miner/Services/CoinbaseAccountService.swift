//
//  CoinbaseAccountService.swift
//  Crypto miner
//

import Foundation
import Combine

@MainActor
class CoinbaseAccountService: ObservableObject {
    @Published var usdtBalance: Double = 0
    @Published var depositAddress: String?
    @Published var depositNetwork: String?
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    var isConnected: Bool { apiClient.hasCredentials() }
    
    private let apiClient = CoinbaseAPIClient()
    
    init() {
        if let creds = CoinbaseCredentialsStore.load() {
            apiClient.setCredentials(apiKey: creds.apiKey, secretKey: creds.secretKey, passphrase: creds.passphrase)
        } else if !Config.coinbaseApiKey.isEmpty, !Config.coinbaseSecretKey.isEmpty, !Config.coinbasePassphrase.isEmpty {
            connect(apiKey: Config.coinbaseApiKey, secretKey: Config.coinbaseSecretKey, passphrase: Config.coinbasePassphrase)
        }
    }
    
    func connect(apiKey: String, secretKey: String, passphrase: String) {
        CoinbaseCredentialsStore.save(apiKey: apiKey, secretKey: secretKey, passphrase: passphrase)
        apiClient.setCredentials(apiKey: apiKey, secretKey: secretKey, passphrase: passphrase)
        objectWillChange.send()
        Task { await refreshBalance() }
    }
    
    func disconnect() {
        CoinbaseCredentialsStore.clear()
        apiClient.clearCredentials()
        usdtBalance = 0
        depositAddress = nil
        depositNetwork = nil
        errorMessage = nil
        objectWillChange.send()
    }
    
    func refreshBalance() async {
        guard apiClient.hasCredentials() else {
            errorMessage = "Not connected"
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        do {
            usdtBalance = try await apiClient.fetchUSDTBalance()
        } catch CoinbaseAPIError.apiError(let msg) {
            errorMessage = msg
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    func fetchDepositAddress(network: String? = nil) async {
        guard apiClient.hasCredentials() else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        do {
            let wallets = try await apiClient.fetchCoinbaseAccounts()
            guard let usdtWallet = wallets.first(where: { $0.currency == "USDT" }) else {
                errorMessage = "No USDT wallet found"
                return
            }
            let addr = try await apiClient.createDepositAddress(coinbaseAccountId: usdtWallet.id, network: network)
            depositAddress = addr.address
            depositNetwork = network ?? addr.network ?? "default"
        } catch CoinbaseAPIError.apiError(let msg) {
            errorMessage = msg
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    func withdraw(coin: String, address: String, amount: Double) async throws {
        try await apiClient.withdraw(currency: coin, cryptoAddress: address, amount: amount)
    }
    
    func fetchProducts() async throws -> [CoinbaseProduct] {
        try await apiClient.fetchProducts()
    }
    
    func placeMarketBuy(productId: String, funds: Double) async throws {
        try await apiClient.placeMarketBuy(productId: productId, funds: funds)
    }
}
