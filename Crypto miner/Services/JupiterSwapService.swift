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
    
    private var quoteURL: String { "\(JupiterConfig.baseURL)/swap/v1/quote" }
    private var swapURL: String { "\(JupiterConfig.baseURL)/swap/v1/swap" }
    private let solMint = "So11111111111111111111111111111111111111112"
    
    /// Execute buy: SOL -> token. Returns tx signature or throws.
    /// - Parameter balanceLamports: If provided and amount &lt; 0.001 SOL gets no route, retries with 0.001 SOL when balance allows.
    func executeBuy(
        outputMint: String,
        solAmountLamports: UInt64,
        walletService: SolanaWalletService,
        slippageBps: Int = 100,
        balanceLamports: UInt64? = nil
    ) async throws -> String {
        guard let keyPair = try walletService.getKeyPair() else {
            throw JupiterError.walletNotConnected
        }
        let userPublicKey = keyPair.publicKey.base58EncodedString
        
        var lastError: Error?
        for attempt in 0..<3 {
            let useSlippage: Int
            switch attempt {
            case 0: useSlippage = slippageBps
            case 1: useSlippage = max(slippageBps, 800)  // 8%
            default: useSlippage = max(slippageBps, 1500) // 15%
            }
            do {
                // 1. Get quote (retry if "No routes found" — token may be indexing or need broader routes)
                var quote: [String: Any]
                do {
                    quote = try await fetchQuote(
                        inputMint: solMint,
                        outputMint: outputMint,
                        amount: solAmountLamports,
                        slippageBps: useSlippage,
                        restrictIntermediateTokens: false // Pump tokens often need broader routes
                    )
                } catch JupiterError.invalidQuote(let msg) where msg.lowercased().contains("no route") {
                    try await Task.sleep(nanoseconds: 10_000_000_000) // 10 sec — Jupiter may still be indexing
                    quote = try await fetchQuote(
                        inputMint: solMint,
                        outputMint: outputMint,
                        amount: solAmountLamports,
                        slippageBps: useSlippage,
                        restrictIntermediateTokens: false
                    )
                }
                
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
            } catch JupiterError.sendFailed(let msg) where msg.contains("Transaction failed on-chain") {
                lastError = JupiterError.sendFailed(msg)
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                throw lastError!
            } catch let err as JupiterError where err.errorDescription?.lowercased().contains("no route") == true {
                // Fallback: small amounts often have no route — try 0.001 then 0.01 SOL (pump server check amount)
                let tryAmounts: [(UInt64, UInt64)] = [(1_000_000, 1_150_000), (10_000_000, 10_150_000)]
                for (fallbackAmount, minBalance) in tryAmounts where solAmountLamports < fallbackAmount {
                    guard let bal = balanceLamports, bal >= minBalance else { continue }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    return try await executeBuy(
                        outputMint: outputMint,
                        solAmountLamports: fallbackAmount,
                        walletService: walletService,
                        slippageBps: slippageBps,
                        balanceLamports: nil
                    )
                }
                throw err
            } catch let err {
                throw err
            }
        }
        throw lastError ?? JupiterError.sendFailed("Transaction failed on-chain")
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

        var lastError: Error?
        for attempt in 0..<3 {
            let useSlippage: Int
            switch attempt {
            case 0: useSlippage = slippageBps
            case 1: useSlippage = max(slippageBps, 800)
            default: useSlippage = max(slippageBps, 1500)
            }
            do {
                var quote: [String: Any]
                do {
                    quote = try await fetchQuote(
                        inputMint: inputMint,
                        outputMint: solMint,
                        amount: tokenAmountRaw,
                        slippageBps: useSlippage,
                        restrictIntermediateTokens: false
                    )
                } catch let err as JupiterError where err.errorDescription?.lowercased().contains("no route") == true {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    quote = try await fetchQuote(
                        inputMint: inputMint,
                        outputMint: solMint,
                        amount: tokenAmountRaw,
                        slippageBps: useSlippage,
                        restrictIntermediateTokens: false
                    )
                }
                let swapTxBase64 = try await fetchSwapTransaction(
                    quoteResponse: quote,
                    userPublicKey: userPublicKey
                )
                return try await signAndSendTransaction(
                    base64Transaction: swapTxBase64,
                    keyPair: keyPair
                )
            } catch JupiterError.sendFailed(let msg) where msg.contains("Transaction failed on-chain") {
                lastError = JupiterError.sendFailed(msg)
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                throw lastError!
            } catch let err {
                throw err
            }
        }
        throw lastError ?? JupiterError.sendFailed("Transaction failed on-chain")
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
        slippageBps: Int,
        restrictIntermediateTokens: Bool = true
    ) async throws -> [String: Any] {
        var components = URLComponents(string: quoteURL)!
        components.queryItems = [
            URLQueryItem(name: "inputMint", value: inputMint),
            URLQueryItem(name: "outputMint", value: outputMint),
            URLQueryItem(name: "amount", value: String(amount)),
            URLQueryItem(name: "slippageBps", value: String(slippageBps)),
            URLQueryItem(name: "restrictIntermediateTokens", value: restrictIntermediateTokens ? "true" : "false"),
            URLQueryItem(name: "maxAccounts", value: "64") // Pump.fun needs 40+, Raydium 45; 64 = Jupiter recommended
        ]
        let url = components.url!
        var request = URLRequest(url: url)
        if !JupiterConfig.apiKey.isEmpty {
            request.setValue(JupiterConfig.apiKey, forHTTPHeaderField: "x-api-key")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if json["inputMint"] != nil { return json }
        // Extract Jupiter's error message (may be in data.error or top-level; error can be object or string)
        let dataObj = json["data"] as? [String: Any]
        let msg: String
        if let s = json["error"] as? String { msg = s }
        else if let obj = json["error"] as? [String: Any], let s = obj["message"] as? String { msg = s }
        else if let s = dataObj?["error"] as? String { msg = s }
        else if let s = json["message"] as? String { msg = s }
        else if let s = json["detail"] as? String { msg = s }
        else if let r = response as? HTTPURLResponse { msg = "HTTP \(r.statusCode)" }
        else { msg = "No route or liquidity" }
        throw JupiterError.invalidQuote(msg)
    }
    
    private func fetchSwapTransaction(
        quoteResponse: [String: Any],
        userPublicKey: String
    ) async throws -> String {
        var request = URLRequest(url: URL(string: swapURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !JupiterConfig.apiKey.isEmpty {
            request.setValue(JupiterConfig.apiKey, forHTTPHeaderField: "x-api-key")
        }
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
            let errObj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"]
            let msg: String
            if let obj = errObj as? [String: Any], let m = obj["message"] as? String { msg = m }
            else if let s = errObj as? String { msg = s }
            else { msg = "Invalid swap response" }
            throw JupiterError.swapFailed(msg)
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
        // skipPreflight: true — avoids 32002 simulation failures on volatile pump tokens
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "sendTransaction",
            "params": [
                base64,
                ["encoding": "base64", "skipPreflight": true, "preflightCommitment": "processed"]
            ]
        ]
        var request = URLRequest(url: URL(string: SolanaRPCConfig.effectiveRPC)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sig = json["result"] as? String else {
            let errObj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            let code = errObj?["code"] as? Int
            let msg = errObj?["message"] as? String ?? "RPC failed"
            let fullMsg = code != nil ? "code = \(code!) — \(msg)" : msg
            throw JupiterError.sendFailed(fullMsg)
        }
        // Verify tx actually succeeded (skipPreflight can return sig for failed txs)
        try await verifyTransaction(signature: sig)
        return sig
    }

    private func verifyTransaction(signature: String) async throws {
        for _ in 0..<45 { // 45 sec max — Solana can be slow during congestion
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 sec
            let body: [String: Any] = [
                "jsonrpc": "2.0", "id": 1, "method": "getTransaction",
                "params": [signature, ["encoding": "jsonParsed", "maxSupportedTransactionVersion": 0]]
            ]
            var req = URLRequest(url: URL(string: SolanaRPCConfig.effectiveRPC)!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tx = json["result"] as? [String: Any],
                  let meta = tx["meta"] as? [String: Any] else { continue }
            if meta["err"] is NSNull {
                return // Tx confirmed, no error
            }
            let errDetail = describeOnChainError(meta["err"])
            throw JupiterError.sendFailed("Transaction failed on-chain\(errDetail)")
        }
        throw JupiterError.sendFailed("Transaction confirmation timeout")
    }

    private func describeOnChainError(_ err: Any?) -> String {
        guard let err = err else { return "" }
        if let dict = err as? [String: Any], let inner = dict["InstructionError"] as? [Any], inner.count >= 2,
           let customObj = (inner[1] as? [String: Any])?["Custom"],
           let custom = (customObj as? NSNumber)?.intValue ?? (customObj as? Int) {
            switch custom {
            case 1: return " (insufficient funds — need more SOL for swap + fees)"
            case 6001: return " (slippage exceeded — try higher slippage)"
            case 6002: return " (invalid route)"
            case 6003: return " (amount too small)"
            case 6024: return " (insufficient funds — need more SOL or token balance)"
            default: return " (code \(custom))"
            }
        }
        return " (\(String(describing: err)))"
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
        var request = URLRequest(url: URL(string: SolanaRPCConfig.effectiveRPC)!)
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
    case invalidQuote(String)
    case swapFailed(String)
    case invalidTransaction
    case signingFailed
    case sendFailed(String)
    case insufficientBalance
    
    var errorDescription: String? {
        switch self {
        case .walletNotConnected: return "Solana wallet not connected"
        case .invalidQuote(let msg): return "Could not get swap quote: \(msg)"
        case .swapFailed(let msg): return "Swap failed: \(msg)"
        case .invalidTransaction: return "Invalid transaction data"
        case .signingFailed: return "Failed to sign transaction"
        case .sendFailed(let msg): return "Send failed: \(msg)"
        case .insufficientBalance: return "Insufficient token balance"
        }
    }
}
