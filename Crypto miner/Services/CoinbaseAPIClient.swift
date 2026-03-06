//
//  CoinbaseAPIClient.swift
//  Crypto miner
//
//  Coinbase Exchange REST API client (api.exchange.coinbase.com)
//  Auth: API key, secret, passphrase. Sign: Base64(HMAC-SHA256(timestamp+method+path+body))
//

import Foundation
import CryptoKit

enum CoinbaseAPIError: Error {
    case invalidCredentials
    case networkError(Error)
    case apiError(message: String)
    case decodingError
}

struct CoinbaseAccount: Decodable {
    let id: String
    let currency: String
    let balance: String
    let available: String
    let hold: String
}

struct CoinbaseWallet: Decodable {
    let id: String
    let currency: String
    let balance: String
    let name: String?
}

struct CoinbaseAddress: Decodable {
    let id: String
    let address: String
    let network: String?
}

struct CoinbaseWithdrawResponse: Decodable {
    let id: String?
    let amount: String?
    let currency: String?
}

struct CoinbaseProduct: Decodable {
    let id: String
    let base_currency: String
    let quote_currency: String
    let status: String?
}

struct CoinbaseOrderResponse: Decodable {
    let id: String?
    let status: String?
}

@MainActor
class CoinbaseAPIClient {
    static let baseURL = "https://api.exchange.coinbase.com"
    
    var isConnected = false
    
    private var apiKey: String?
    private var secretKey: String?
    private var passphrase: String?
    
    func setCredentials(apiKey: String, secretKey: String, passphrase: String) {
        self.apiKey = apiKey
        self.secretKey = secretKey
        self.passphrase = passphrase
        self.isConnected = !apiKey.isEmpty && !secretKey.isEmpty && !passphrase.isEmpty
    }
    
    func clearCredentials() {
        apiKey = nil
        secretKey = nil
        passphrase = nil
        isConnected = false
    }
    
    func hasCredentials() -> Bool {
        guard let k = apiKey, let s = secretKey, let p = passphrase else { return false }
        return !k.isEmpty && !s.isEmpty && !p.isEmpty
    }
    
    /// GET /accounts - trading accounts (USDT, USD, etc.)
    func fetchAccounts() async throws -> [CoinbaseAccount] {
        try await signedRequest(method: "GET", path: "/accounts")
    }
    
    /// Get USDT balance from trading accounts
    func fetchUSDTBalance() async throws -> Double {
        let accounts = try await fetchAccounts()
        let usdt = accounts.first { $0.currency == "USDT" }
        return Double(usdt?.available ?? "0") ?? 0
    }
    
    /// GET /coinbase-accounts - wallets for deposits
    func fetchCoinbaseAccounts() async throws -> [CoinbaseWallet] {
        try await signedRequest(method: "GET", path: "/coinbase-accounts")
    }
    
    /// POST /coinbase-accounts/{id}/addresses - create deposit address
    func createDepositAddress(coinbaseAccountId: String, network: String? = nil) async throws -> CoinbaseAddress {
        var body: [String: Any] = [:]
        if let net = network {
            body["network"] = net
        }
        let bodyData = body.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: body)
        return try await signedRequest(method: "POST", path: "/coinbase-accounts/\(coinbaseAccountId)/addresses", body: bodyData)
    }
    
    /// POST /withdrawals/crypto - withdraw to external address
    func withdraw(currency: String, cryptoAddress: String, amount: Double) async throws {
        let body: [String: Any] = [
            "currency": currency,
            "crypto_address": cryptoAddress,
            "amount": String(amount)
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let _: CoinbaseWithdrawResponse = try await signedRequest(method: "POST", path: "/withdrawals/crypto", body: bodyData)
    }
    
    /// GET /products - list available trading pairs
    func fetchProducts() async throws -> [CoinbaseProduct] {
        let products: [CoinbaseProduct] = try await signedRequest(method: "GET", path: "/products")
        return products.filter { $0.status != "delisted" }
    }
    
    /// POST /orders - place market buy (funds = amount in quote currency, e.g. USD)
    func placeMarketBuy(productId: String, funds: Double) async throws {
        let body: [String: Any] = [
            "product_id": productId,
            "side": "buy",
            "type": "market",
            "funds": String(format: "%.2f", funds)
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let _: CoinbaseOrderResponse = try await signedRequest(method: "POST", path: "/orders", body: bodyData)
    }
    
    private func signedRequest<T: Decodable>(
        method: String,
        path: String,
        body: Data? = nil
    ) async throws -> T {
        guard let apiKey = apiKey, let secretKey = secretKey, let passphrase = passphrase else {
            throw CoinbaseAPIError.invalidCredentials
        }
        
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let bodyString = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let message = timestamp + method + path + bodyString
        
        // Coinbase secret is base64-encoded; decode before HMAC
        let keyData: Data
        if let decoded = Data(base64Encoded: secretKey) {
            keyData = decoded
        } else {
            keyData = Data(secretKey.utf8)
        }
        let messageData = Data(message.utf8)
        let signature = HMAC<SHA256>.authenticationCode(for: messageData, using: SymmetricKey(data: keyData))
        let signBase64 = Data(signature).base64EncodedString()
        
        guard let url = URL(string: Self.baseURL + path) else {
            throw CoinbaseAPIError.decodingError
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "CB-ACCESS-KEY")
        request.setValue(passphrase, forHTTPHeaderField: "CB-ACCESS-PASSPHRASE")
        request.setValue(timestamp, forHTTPHeaderField: "CB-ACCESS-TIMESTAMP")
        request.setValue(signBase64, forHTTPHeaderField: "CB-ACCESS-SIGN")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CoinbaseAPIError.apiError(message: "\(http.statusCode): \(msg)")
        }
        
        return try JSONDecoder().decode(T.self, from: data)
    }
}
