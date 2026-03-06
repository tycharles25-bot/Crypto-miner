//
//  GeckoTerminalService.swift
//  Crypto miner
//
//  Fetches trending DEX pools across all chains - full crypto universe.
//  Covers Solana, Base, Ethereum, BSC, Polygon, Arbitrum, etc.
//

import Foundation
import Combine

struct GeckoPool: Decodable {
    let id: String
    let type: String
    let attributes: GeckoPoolAttributes
    let relationships: GeckoRelationships?
}

struct GeckoPoolAttributes: Decodable {
    let base_token_price_usd: String?
    let address: String
    let name: String
    let pool_created_at: String?
    let fdv_usd: String?
    let market_cap_usd: String?
    let price_change_percentage: GeckoPriceChange?
    let volume_usd: GeckoVolume?
    let reserve_in_usd: String?
}

struct GeckoPriceChange: Decodable {
    let m5: String?
    let m15: String?
    let m30: String?
    let h1: String?
    let h6: String?
    let h24: String?
}

struct GeckoVolume: Decodable {
    let m5: String?
    let m15: String?
    let m30: String?
    let h1: String?
    let h6: String?
    let h24: String?
}

struct GeckoRelationships: Decodable {
    let network: GeckoRelation?
    let base_token: GeckoRelation?
    let quote_token: GeckoRelation?
}

struct GeckoRelation: Decodable {
    let data: GeckoRelationData?
}

struct GeckoRelationData: Decodable {
    let id: String
    let type: String
}

struct GeckoTrendingResponse: Decodable {
    let data: [GeckoPool]?
}

struct GeckoOHLCVResponse: Decodable {
    let data: GeckoOHLCVData?
}

struct GeckoOHLCVData: Decodable {
    let id: String?
    let type: String?
    let attributes: GeckoOHLCVAttributes?
}

struct GeckoOHLCVAttributes: Decodable {
    let ohlcv_list: [[Double]]?  // [timestamp, open, high, low, close, volume]
}

/// How a pump is defined
enum PumpDefinition: String, CaseIterable {
    case threshold24h = "24h %"
    case consecutive3h = "10%/hr × 3"
    case consecutive3x20min = "10%/20min × 3"
    case single20min = "10%/20min × 1"
    case hundredPerc10min = "100%/10min"
    case fiftyPerc20min = "50%/20min"
    
    /// Cashout delay for auto-deposit formulas. nil = no auto cashout.
    var cashoutAfterSeconds: TimeInterval? {
        switch self {
        case .hundredPerc10min: return 3600   // 1 hour
        case .fiftyPerc20min: return 7200      // 2 hours
        default: return nil
        }
    }
}

@MainActor
class GeckoTerminalService: ObservableObject {
    @Published var isScanning = false
    @Published var lastUpdate = Date()
    @Published var poolCount = 0
    
    private let baseURL = "https://api.geckoterminal.com/api/v2"
    private var pollTask: Task<Void, Never>?
    
    /// Networks to scan - covers millions of DEX tokens
    private let scanNetworks = ["solana", "base", "eth", "arbitrum", "bsc"]
    
    /// Fetch trending pools for a specific network
    func fetchTrendingPools(network: String) async throws -> [PumpAlert] {
        let url = URL(string: "\(baseURL)/networks/\(network)/trending_pools")!
        var request = URLRequest(url: url)
        request.setValue("application/json;version=20230203", forHTTPHeaderField: "Accept")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(GeckoTrendingResponse.self, from: data)
        
        guard let pools = response.data else { return [] }
        
        return pools.compactMap { pool -> PumpAlert? in
            guard let change = pool.attributes.price_change_percentage,
                  let h24Str = change.h24,
                  let h24 = Double(h24Str) else { return nil }
            
            let price = Double(pool.attributes.base_token_price_usd ?? "0") ?? 0
            let vol24 = Double(pool.attributes.volume_usd?.h24 ?? "0") ?? 0
            let name = pool.attributes.name.components(separatedBy: " / ").first ?? pool.attributes.name
            
            // Extract base token mint: "solana_8opvqa..." -> "8opvqa..."
            let baseMint: String? = {
                guard let id = pool.relationships?.base_token?.data?.id else { return nil }
                return id.components(separatedBy: "_").last
            }()
            
            return PumpAlert(
                id: pool.id,
                symbol: "\(name) (\(network))",
                priceChangePercent: h24,
                price: price,
                volume: vol24,
                quoteVolume: vol24,
                detectedAt: Date(),
                network: network,
                baseTokenMint: baseMint
            )
        }
    }
    
    /// Supported networks - each has thousands to millions of tokens
    static let networks = ["solana", "base", "ethereum", "arbitrum", "bsc", "polygon_pos", "avalanche", "optimism", "fantom", "ronin"]
    
    /// Fetch hourly OHLCV for a pool. Returns [[timestamp, open, high, low, close, volume]] newest first.
    func fetchOHLCV(network: String, poolAddress: String, limit: Int = 5) async throws -> [[Double]] {
        let url = URL(string: "\(baseURL)/networks/\(network)/pools/\(poolAddress)/ohlcv/hour?aggregate=1&limit=\(limit)")!
        var request = URLRequest(url: url)
        request.setValue("application/json;version=20230203", forHTTPHeaderField: "Accept")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(GeckoOHLCVResponse.self, from: data)
        return response.data?.attributes?.ohlcv_list ?? []
    }
    
    /// Contribute OHLCV data to server for crowdsourced indexing (each client = more coverage)
    private func contributePoolData(network: String, poolId: String, tokenMint: String?, symbol: String, ohlcv: [[Double]]) {
        guard ContributeConfig.isEnabled,
              let url = ContributeConfig.contributeURL,
              let mint = tokenMint else { return }
        let payload: [String: Any] = [
            "source": "gecko",
            "network": network,
            "pools": [["poolId": poolId, "tokenMint": mint, "symbol": symbol, "ohlcv": ohlcv]]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        Task {
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    /// Fetch 1-minute OHLCV. Newest first. Need 65+ for 3×20min check.
    func fetchOHLCVMinute(network: String, poolAddress: String, limit: Int = 65) async throws -> [[Double]] {
        let url = URL(string: "\(baseURL)/networks/\(network)/pools/\(poolAddress)/ohlcv/minute?aggregate=1&limit=\(limit)")!
        var request = URLRequest(url: url)
        request.setValue("application/json;version=20230203", forHTTPHeaderField: "Accept")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(GeckoOHLCVResponse.self, from: data)
        return response.data?.attributes?.ohlcv_list ?? []
    }
    
    /// Check if any 10-min interval had >= minPercent gain. Uses 1-min candles; 10-min = indices 0,9,19,29,39,49,59.
    func has100Percent10minPump(minuteOhlcv: [[Double]], minPercent: Double = 100) -> Bool {
        guard minuteOhlcv.count >= 60 else { return false }
        let closes = minuteOhlcv.map { $0[4] }
        for (prev, curr) in [(59, 49), (49, 39), (39, 29), (29, 19), (19, 9), (9, 0)] {
            guard closes[prev] > 0 else { continue }
            let gain = (closes[curr] / closes[prev] - 1) * 100
            if gain >= minPercent { return true }
        }
        return false
    }
    
    /// Check if any single 20-min interval had >= minPercent gain. Catches earliest stage of pumps.
    /// Uses 1-min candles: 20-min close at indices 0, 19, 39, 59. Needs 60+ candles.
    func hasSingle20minPump(minuteOhlcv: [[Double]], minPercent: Double = 10) -> Bool {
        guard minuteOhlcv.count >= 60 else { return false }
        let closes = minuteOhlcv.map { $0[4] }
        for (prev, curr) in [(59, 39), (39, 19), (19, 0)] {
            guard closes[prev] > 0 else { continue }
            let gain = (closes[curr] / closes[prev] - 1) * 100
            if gain >= minPercent { return true }
        }
        return false
    }
    
    /// Check if last 3 consecutive 20-min intervals each had >= minPercent gain.
    /// Uses 1-min candles: 20-min close at indices 0, 19, 39, 59. Needs 60+ candles.
    func has3Consecutive20minPumps(minuteOhlcv: [[Double]], minPercent: Double = 10) -> Bool {
        guard minuteOhlcv.count >= 60 else { return false }
        let closes = minuteOhlcv.map { $0[4] }
        let i0 = 0
        let i1 = 19
        let i2 = 39
        let i3 = 59
        for (prev, curr) in [(i3, i2), (i2, i1), (i1, i0)] {  // 60→40min, 40→20min, 20→0min
            guard closes[prev] > 0 else { return false }
            let gain = (closes[curr] / closes[prev] - 1) * 100
            if gain < minPercent { return false }
        }
        return true
    }
    
    /// Check if last 3 hourly candles each had >= minPercent gain. Needs 4+ candles.
    /// OHLCV order: newest first. closes[0]=now, closes[1]=1h ago, etc.
    func has3ConsecutiveHourlyPumps(ohlcv: [[Double]], minPercent: Double = 10) -> Bool {
        guard ohlcv.count >= 4 else { return false }
        let closes = ohlcv.map { $0[4] }  // close is index 4
        for i in 0..<3 {
            guard closes[i + 1] > 0 else { return false }
            let gain = (closes[i] / closes[i + 1] - 1) * 100
            if gain < minPercent { return false }
        }
        return true
    }
    
    /// Fetch pumps using 3×10%/hr rule. Fetches trending pools, then OHLCV for each.
    func fetchPumpsWith3hRule(network: String, minHourlyPercent: Double = 10) async throws -> [PumpAlert] {
        let url = URL(string: "\(baseURL)/networks/\(network)/trending_pools")!
        var request = URLRequest(url: url)
        request.setValue("application/json;version=20230203", forHTTPHeaderField: "Accept")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(GeckoTrendingResponse.self, from: data)
        guard let pools = response.data else { return [] }
        
        var alerts: [PumpAlert] = []
        for pool in pools {
            let poolAddr = pool.attributes.address
            let name = pool.attributes.name.components(separatedBy: " / ").first ?? pool.attributes.name
            let baseMint: String? = {
                guard let id = pool.relationships?.base_token?.data?.id else { return nil }
                return id.components(separatedBy: "_").last
            }()
            do {
                let ohlcv = try await fetchOHLCV(network: network, poolAddress: poolAddr)
                contributePoolData(network: network, poolId: pool.id, tokenMint: baseMint, symbol: name, ohlcv: ohlcv)
                guard has3ConsecutiveHourlyPumps(ohlcv: ohlcv, minPercent: minHourlyPercent) else { continue }
                
                let closes = ohlcv.map { $0[4] }
                let lastClose = closes.last ?? 0
                let threeHoursAgo = closes.count >= 4 ? closes[closes.count - 4] : lastClose
                let totalChange = threeHoursAgo > 0 ? (lastClose / threeHoursAgo - 1) * 100 : 0
                
                let price = Double(pool.attributes.base_token_price_usd ?? "0") ?? lastClose
                let vol24 = Double(pool.attributes.volume_usd?.h24 ?? "0") ?? 0
                
                alerts.append(PumpAlert(
                    id: pool.id,
                    symbol: "\(name) (\(network))",
                    priceChangePercent: totalChange,
                    price: price,
                    volume: vol24,
                    quoteVolume: vol24,
                    detectedAt: Date(),
                    network: network,
                    baseTokenMint: baseMint
                ))
            } catch {
                continue  // Skip pool if OHLCV fails
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)  // 2.5s between OHLCV calls (rate limit)
        }
        return alerts
    }
    
    /// Fetch pumps using 3×10%/20min rule. Fetches trending pools, then 1-min OHLCV for each.
    func fetchPumpsWith20minRule(network: String, minPercent: Double = 10) async throws -> [PumpAlert] {
        let url = URL(string: "\(baseURL)/networks/\(network)/trending_pools")!
        var request = URLRequest(url: url)
        request.setValue("application/json;version=20230203", forHTTPHeaderField: "Accept")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(GeckoTrendingResponse.self, from: data)
        guard let pools = response.data else { return [] }
        
        var alerts: [PumpAlert] = []
        for pool in pools {
            let poolAddr = pool.attributes.address
            let name = pool.attributes.name.components(separatedBy: " / ").first ?? pool.attributes.name
            let baseMint: String? = {
                guard let id = pool.relationships?.base_token?.data?.id else { return nil }
                return id.components(separatedBy: "_").last
            }()
            do {
                let minuteOhlcv = try await fetchOHLCVMinute(network: network, poolAddress: poolAddr)
                contributePoolData(network: network, poolId: pool.id, tokenMint: baseMint, symbol: name, ohlcv: minuteOhlcv)
                guard has3Consecutive20minPumps(minuteOhlcv: minuteOhlcv, minPercent: minPercent) else { continue }
                
                let closes = minuteOhlcv.map { $0[4] }
                let lastClose = closes[0]
                let sixtyMinAgo = closes.count > 59 ? closes[59] : lastClose
                let totalChange = sixtyMinAgo > 0 ? (lastClose / sixtyMinAgo - 1) * 100 : 0
                
                let price = Double(pool.attributes.base_token_price_usd ?? "0") ?? lastClose
                let vol24 = Double(pool.attributes.volume_usd?.h24 ?? "0") ?? 0
                
                alerts.append(PumpAlert(
                    id: pool.id,
                    symbol: "\(name) (\(network))",
                    priceChangePercent: totalChange,
                    price: price,
                    volume: vol24,
                    quoteVolume: vol24,
                    detectedAt: Date(),
                    network: network,
                    baseTokenMint: baseMint
                ))
            } catch {
                continue
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
        return alerts
    }
    
    /// Fetch pumps using single 20-min rule. Any one 20-min interval with >= minPercent = pump.
    func fetchPumpsWithSingle20minRule(network: String, minPercent: Double = 10) async throws -> [PumpAlert] {
        let url = URL(string: "\(baseURL)/networks/\(network)/trending_pools")!
        var request = URLRequest(url: url)
        request.setValue("application/json;version=20230203", forHTTPHeaderField: "Accept")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(GeckoTrendingResponse.self, from: data)
        guard let pools = response.data else { return [] }
        
        var alerts: [PumpAlert] = []
        for pool in pools {
            let poolAddr = pool.attributes.address
            let name = pool.attributes.name.components(separatedBy: " / ").first ?? pool.attributes.name
            let baseMint: String? = {
                guard let id = pool.relationships?.base_token?.data?.id else { return nil }
                return id.components(separatedBy: "_").last
            }()
            do {
                let minuteOhlcv = try await fetchOHLCVMinute(network: network, poolAddress: poolAddr)
                contributePoolData(network: network, poolId: pool.id, tokenMint: baseMint, symbol: name, ohlcv: minuteOhlcv)
                guard hasSingle20minPump(minuteOhlcv: minuteOhlcv, minPercent: minPercent) else { continue }
                
                let closes = minuteOhlcv.map { $0[4] }
                let lastClose = closes[0]
                let sixtyMinAgo = closes.count > 59 ? closes[59] : lastClose
                let totalChange = sixtyMinAgo > 0 ? (lastClose / sixtyMinAgo - 1) * 100 : 0
                
                let price = Double(pool.attributes.base_token_price_usd ?? "0") ?? lastClose
                let vol24 = Double(pool.attributes.volume_usd?.h24 ?? "0") ?? 0
                
                alerts.append(PumpAlert(
                    id: pool.id,
                    symbol: "\(name) (\(network))",
                    priceChangePercent: totalChange,
                    price: price,
                    volume: vol24,
                    quoteVolume: vol24,
                    detectedAt: Date(),
                    network: network,
                    baseTokenMint: baseMint
                ))
            } catch {
                continue
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
        return alerts
    }
    
    /// Fetch pumps using 100%/10min rule. Any 10-min interval with >= 100% = deposit trigger. Cash out 1h later.
    func fetchPumpsWith100perc10minRule(network: String, minPercent: Double = 100) async throws -> [PumpAlert] {
        let url = URL(string: "\(baseURL)/networks/\(network)/trending_pools")!
        var request = URLRequest(url: url)
        request.setValue("application/json;version=20230203", forHTTPHeaderField: "Accept")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(GeckoTrendingResponse.self, from: data)
        guard let pools = response.data else { return [] }
        
        var alerts: [PumpAlert] = []
        for pool in pools {
            let poolAddr = pool.attributes.address
            let name = pool.attributes.name.components(separatedBy: " / ").first ?? pool.attributes.name
            let baseMint: String? = {
                guard let id = pool.relationships?.base_token?.data?.id else { return nil }
                return id.components(separatedBy: "_").last
            }()
            do {
                let minuteOhlcv = try await fetchOHLCVMinute(network: network, poolAddress: poolAddr)
                contributePoolData(network: network, poolId: pool.id, tokenMint: baseMint, symbol: name, ohlcv: minuteOhlcv)
                guard has100Percent10minPump(minuteOhlcv: minuteOhlcv, minPercent: minPercent) else { continue }
                
                let closes = minuteOhlcv.map { $0[4] }
                let lastClose = closes[0]
                let sixtyMinAgo = closes.count > 59 ? closes[59] : lastClose
                let totalChange = sixtyMinAgo > 0 ? (lastClose / sixtyMinAgo - 1) * 100 : 0
                
                let price = Double(pool.attributes.base_token_price_usd ?? "0") ?? lastClose
                let vol24 = Double(pool.attributes.volume_usd?.h24 ?? "0") ?? 0
                
                alerts.append(PumpAlert(
                    id: pool.id,
                    symbol: "\(name) (\(network))",
                    priceChangePercent: totalChange,
                    price: price,
                    volume: vol24,
                    quoteVolume: vol24,
                    detectedAt: Date(),
                    network: network,
                    baseTokenMint: baseMint
                ))
            } catch {
                continue
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
        return alerts
    }
    
    /// Fetch pumps using 50%/20min rule. Any 20-min interval with >= 50% = deposit trigger. Cash out 2h later.
    func fetchPumpsWith50perc20minRule(network: String, minPercent: Double = 50) async throws -> [PumpAlert] {
        let url = URL(string: "\(baseURL)/networks/\(network)/trending_pools")!
        var request = URLRequest(url: url)
        request.setValue("application/json;version=20230203", forHTTPHeaderField: "Accept")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(GeckoTrendingResponse.self, from: data)
        guard let pools = response.data else { return [] }
        
        var alerts: [PumpAlert] = []
        for pool in pools {
            let poolAddr = pool.attributes.address
            let name = pool.attributes.name.components(separatedBy: " / ").first ?? pool.attributes.name
            let baseMint: String? = {
                guard let id = pool.relationships?.base_token?.data?.id else { return nil }
                return id.components(separatedBy: "_").last
            }()
            do {
                let minuteOhlcv = try await fetchOHLCVMinute(network: network, poolAddress: poolAddr)
                contributePoolData(network: network, poolId: pool.id, tokenMint: baseMint, symbol: name, ohlcv: minuteOhlcv)
                guard hasSingle20minPump(minuteOhlcv: minuteOhlcv, minPercent: minPercent) else { continue }
                
                let closes = minuteOhlcv.map { $0[4] }
                let lastClose = closes[0]
                let sixtyMinAgo = closes.count > 59 ? closes[59] : lastClose
                let totalChange = sixtyMinAgo > 0 ? (lastClose / sixtyMinAgo - 1) * 100 : 0
                
                let price = Double(pool.attributes.base_token_price_usd ?? "0") ?? lastClose
                let vol24 = Double(pool.attributes.volume_usd?.h24 ?? "0") ?? 0
                
                alerts.append(PumpAlert(
                    id: pool.id,
                    symbol: "\(name) (\(network))",
                    priceChangePercent: totalChange,
                    price: price,
                    volume: vol24,
                    quoteVolume: vol24,
                    detectedAt: Date(),
                    network: network,
                    baseTokenMint: baseMint
                ))
            } catch {
                continue
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
        return alerts
    }
    
    func startScanning(minThreshold: Double, pumpDefinition: PumpDefinition = .threshold24h, onAlerts: @escaping ([PumpAlert]) -> Void) {
        guard !isScanning else { return }
        isScanning = true
        
        pollTask = Task {
            while !Task.isCancelled && isScanning {
                do {
                    var allAlerts: [PumpAlert] = []
                    var seen = Set<String>()
                    
                    switch pumpDefinition {
                    case .threshold24h:
                        for network in scanNetworks {
                            let alerts = try await fetchTrendingPools(network: network)
                            for a in alerts where !seen.contains(a.id) {
                                seen.insert(a.id)
                                allAlerts.append(a)
                            }
                            try? await Task.sleep(nanoseconds: 7_000_000_000)
                        }
                        allAlerts = allAlerts.filter { $0.priceChangePercent >= minThreshold }
                    case .consecutive3h:
                        let hourlyPercent = minThreshold > 0 ? minThreshold : 10
                        for network in scanNetworks {
                            let alerts = try await fetchPumpsWith3hRule(network: network, minHourlyPercent: hourlyPercent)
                            for a in alerts where !seen.contains(a.id) {
                                seen.insert(a.id)
                                allAlerts.append(a)
                            }
                            try? await Task.sleep(nanoseconds: 7_000_000_000)
                        }
                    case .consecutive3x20min:
                        let pct = minThreshold > 0 ? minThreshold : 10
                        for network in scanNetworks {
                            let alerts = try await fetchPumpsWith20minRule(network: network, minPercent: pct)
                            for a in alerts where !seen.contains(a.id) {
                                seen.insert(a.id)
                                allAlerts.append(a)
                            }
                            try? await Task.sleep(nanoseconds: 7_000_000_000)
                        }
                    case .single20min:
                        let pct = minThreshold > 0 ? minThreshold : 10
                        for network in scanNetworks {
                            let alerts = try await fetchPumpsWithSingle20minRule(network: network, minPercent: pct)
                            for a in alerts where !seen.contains(a.id) {
                                seen.insert(a.id)
                                allAlerts.append(a)
                            }
                            try? await Task.sleep(nanoseconds: 7_000_000_000)
                        }
                    case .hundredPerc10min:
                        let pct = minThreshold > 0 ? minThreshold : 100
                        for network in scanNetworks {
                            let alerts = try await fetchPumpsWith100perc10minRule(network: network, minPercent: pct)
                            for a in alerts where !seen.contains(a.id) {
                                seen.insert(a.id)
                                allAlerts.append(a)
                            }
                            try? await Task.sleep(nanoseconds: 7_000_000_000)
                        }
                    case .fiftyPerc20min:
                        let pct = minThreshold > 0 ? minThreshold : 50
                        for network in scanNetworks {
                            let alerts = try await fetchPumpsWith50perc20minRule(network: network, minPercent: pct)
                            for a in alerts where !seen.contains(a.id) {
                                seen.insert(a.id)
                                allAlerts.append(a)
                            }
                            try? await Task.sleep(nanoseconds: 7_000_000_000)
                        }
                    }
                    
                    let sorted = allAlerts.sorted { $0.priceChangePercent > $1.priceChangePercent }
                    
                    await MainActor.run {
                        poolCount = allAlerts.count
                        lastUpdate = Date()
                        onAlerts(Array(sorted.prefix(100)))
                    }
                } catch {
                    print("GeckoTerminal error: \(error)")
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 1 min between full scans
            }
        }
    }
    
    func stopScanning() {
        isScanning = false
        pollTask?.cancel()
        pollTask = nil
    }
}
