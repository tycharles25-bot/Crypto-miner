//
//  JupiterSwapService.swift
//  Crypto miner
//
//  Executes Jupiter swaps on Solana programmatically (fully automatic).
//

import Foundation
import Combine
import CryptoKit
import SolanaSwift

@MainActor
class JupiterSwapService: ObservableObject {
    @Published var lastError: String?
    
    private let quoteURL = "https://api.jup.ag/swap/v1/quote"
    private let swapURL = "https://api.jup.ag/swap/v1/swap"
    private let solMint = "So11111111111111111111111111111111111111112"
    private let solanaRPC = "https://api.mainnet-beta.solana.com"
    
    /// Execute buy: SOL -> token. Returns tx signature or throws.
    func executeBuy(
        outputMint: String,
        solAmountLamports: UInt64,
        walletService: SolanaWalletService,
        slippageBps: Int = 100
    ) async throws -> String {
        guard let keyPair = try walletService.getKeyPair() else {
            throw JupiterError.walletNotConnected
        }
        let userPublicKey = keyPair.publicKey.base58EncodedString
        
        // 1. Get quote
        let quote = try await fetchQuote(
            inputMint: solMint,
            outputMint: outputMint,
            amount: solAmountLamports,
            slippageBps: slippageBps
        )
        
        // 2. Get swap transaction
        let swapTxBase64 = try await fetchSwapTransaction(
            quoteResponse: quote,
            userPublicKey: userPublicKey
        )
        
        // 3. Sign and send
        return try await signAndSendTransaction(
            base64Transaction: swapTxBase64,
            keyPair: keyPair
        )
    }
    
    /// Execute sell: token -> SOL. Returns tx signature or throws.
    func executeSell(
        inputMint: String,
        tokenAmountRaw: UInt64,
        walletService: SolanaWalletService,
        slippageBps: Int = 100
    ) async throws -> String {
        guard let keyPair = try walletService.getKeyPair() else {
            throw JupiterError.walletNotConnected
        }
        let userPublicKey = keyPair.publicKey.base58EncodedString
        
        let quote = try await fetchQuote(
            inputMint: inputMint,
            outputMint: solMint,
            amount: tokenAmountRaw,
            slippageBps: slippageBps
        )
        
        let swapTxBase64 = try await fetchSwapTransaction(
            quoteResponse: quote,
            userPublicKey: userPublicKey
        )
        
        return try await signAndSendTransaction(
            base64Transaction: swapTxBase64,
            keyPair: keyPair
        )
    }
    
    /// Sell entire token balance. Fetches balance first.
    func executeSellAll(
        inputMint: String,
        walletService: SolanaWalletService,
        slippageBps: Int = 100
    ) async throws -> String {
        guard let keyPair = try walletService.getKeyPair() else {
            throw JupiterError.walletNotConnected
        }
        let userPublicKey = keyPair.publicKey.base58EncodedString
        
        // Get token balance - we need the token account. Use getTokenAccountsByOwner.
        let balance = try await fetchTokenBalance(userPublicKey: userPublicKey, mint: inputMint)
        guard balance > 0 else {
            throw JupiterError.insufficientBalance
        }
        
        return try await executeSell(
            inputMint: inputMint,
            tokenAmountRaw: balance,
            walletService: walletService,
            slippageBps: slippageBps
        )
    }
    
    // MARK: - Private
    
    private func fetchQuote(
        inputMint: String,
        outputMint: String,
        amount: UInt64,
        slippageBps: Int
    ) async throws -> [String: Any] {
        var components = URLComponents(string: quoteURL)!
        components.queryItems = [
            URLQueryItem(name: "inputMint", value: inputMint),
            URLQueryItem(name: "outputMint", value: outputMint),
            URLQueryItem(name: "amount", value: String(amount)),
            URLQueryItem(name: "slippageBps", value: String(slippageBps)),
            URLQueryItem(name: "restrictIntermediateTokens", value: "true")
        ]
        let url = components.url!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["inputMint"] != nil else {
            throw JupiterError.invalidQuote
        }
        return json
    }
    
    private func fetchSwapTransaction(
        quoteResponse: [String: Any],
        userPublicKey: String
    ) async throws -> String {
        var request = URLRequest(url: URL(string: swapURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "quoteResponse": quoteResponse,
            "userPublicKey": userPublicKey,
            "dynamicComputeUnitLimit": true,
            "prioritizationFeeLamports": "auto"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let swapTx = json["swapTransaction"] as? String else {
            let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] ?? "Invalid swap response"
            throw JupiterError.swapFailed(String(describing: err))
        }
        return swapTx
    }
    
    private func signAndSendTransaction(base64Transaction: String, keyPair: KeyPair) async throws -> String {
        guard let txData = Data(base64Encoded: base64Transaction) else {
            throw JupiterError.invalidTransaction
        }
        var bytes = [UInt8](txData)
        
        // Parse VersionedTransaction: [compact-u16 num_sigs][sig0..sigN][message]
        let (numSigs, sigOffset) = readCompactU16(bytes)
        let messageStart = sigOffset + numSigs * 64
        guard bytes.count > messageStart else {
            throw JupiterError.invalidTransaction
        }
        let message = Data(bytes[messageStart...])
        
        // Sign message with Ed25519 (SolanaSwift uses TweetNacl internally)
        let signature = try signMessage(message, secretKey: keyPair.secretKey)
        guard signature.count == 64 else {
            throw JupiterError.signingFailed
        }
        
        // Replace first signature
        for i in 0..<64 {
            bytes[sigOffset + i] = signature[i]
        }
        
        let signedBase64 = Data(bytes).base64EncodedString()
        return try await sendTransaction(signedBase64)
    }
    
    private func signMessage(_ message: Data, secretKey: Data) throws -> Data {
        // Ed25519: secretKey is 64 bytes (32 seed + 32 public). CryptoKit needs 32-byte seed.
        let seed = secretKey.prefix(32)
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        return Data(try privateKey.signature(for: message))
    }
    
    private func readCompactU16(_ bytes: [UInt8]) -> (Int, Int) {
        var offset = 0
        var result = 0
        var shift = 0
        while offset < bytes.count {
            let byte = Int(bytes[offset])
            offset += 1
            result |= (byte & 0x7f) << shift
            if (byte & 0x80) == 0 { break }
            shift += 7
        }
        return (result, offset)
    }
    
    private func sendTransaction(_ base64: String) async throws -> String {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "sendTransaction",
            "params": [
                base64,
                ["encoding": "base64", "skipPreflight": false]
            ]
        ]
        var request = URLRequest(url: URL(string: solanaRPC)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? String else {
            let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] ?? "RPC failed"
            throw JupiterError.sendFailed(String(describing: err))
        }
        return result
    }
    
    private func fetchTokenBalance(userPublicKey: String, mint: String) async throws -> UInt64 {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getTokenAccountsByOwner",
            "params": [
                userPublicKey,
                ["mint": mint],
                ["encoding": "jsonParsed"]
            ]
        ]
        var request = URLRequest(url: URL(string: solanaRPC)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let value = result["value"] as? [[String: Any]] else {
            return 0
        }
        for item in value {
            guard let account = item["account"] as? [String: Any],
                  let data = account["data"] as? [String: Any],
                  let parsed = data["parsed"] as? [String: Any],
                  let info = parsed["info"] as? [String: Any],
                  let tokenAmount = info["tokenAmount"] as? [String: Any],
                  let amountStr = tokenAmount["amount"] as? String,
                  let amount = UInt64(amountStr) else { continue }
            return amount
        }
        return 0
    }
}

enum JupiterError: LocalizedError {
    case walletNotConnected
    case invalidQuote
    case swapFailed(String)
    case invalidTransaction
    case signingFailed
    case sendFailed(String)
    case insufficientBalance
    
    var errorDescription: String? {
        switch self {
        case .walletNotConnected: return "Solana wallet not connected"
        case .invalidQuote: return "Could not get swap quote"
        case .swapFailed(let msg): return "Swap failed: \(msg)"
        case .invalidTransaction: return "Invalid transaction data"
        case .signingFailed: return "Failed to sign transaction"
        case .sendFailed(let msg): return "Send failed: \(msg)"
        case .insufficientBalance: return "Insufficient token balance"
        }
    }
}
