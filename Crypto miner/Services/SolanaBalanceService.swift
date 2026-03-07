//
//  SolanaBalanceService.swift
//  Crypto miner
//
//  Fetches SOL balance from RPC.
//

import Foundation

@Observable
final class SolanaBalanceService {
    var balanceLamports: UInt64?
    var lastError: String?
    
    private var rpcURL: String { SolanaRPCConfig.effectiveRPC }
    
    func fetchBalance(publicKey: String) async {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getBalance",
            "params": [publicKey]
        ]
        guard let url = URL(string: rpcURL),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            await MainActor.run { lastError = "Invalid request" }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let value = result["value"] as? Int else {
                await MainActor.run { lastError = "Invalid response" }
                return
            }
            await MainActor.run {
                balanceLamports = UInt64(value)
                lastError = nil
            }
        } catch {
            await MainActor.run {
                lastError = error.localizedDescription
                balanceLamports = nil
            }
        }
    }
}
