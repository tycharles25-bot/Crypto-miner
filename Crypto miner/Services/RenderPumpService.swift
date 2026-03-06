//
//  RenderPumpService.swift
//  Crypto miner
//
//  Fetches pump alerts from Render PumpApi server.
//

import Foundation
import Combine

struct RenderPumpAlert: Codable {
    let id: String
    let symbol: String
    let priceChangePercent: Double
    let price: Double
    let network: String
    let baseTokenMint: String
    let detectedAt: Double?
}

struct RenderAlertsResponse: Codable {
    let alerts: [RenderPumpAlert]
    let tokensTracked: Int?
    let samplesTotal: Int?
}

@MainActor
class RenderPumpService: ObservableObject {
    @Published var alerts: [PumpAlert] = []
    @Published var isConnected = false
    @Published var lastError: String?
    @Published var tokensTracked = 0
    @Published var samplesTotal = 0

    private var pollTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 10

    var serverURL: String {
        RenderConfig.serverURL
    }

    func startPolling() {
        stopPolling()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                await fetchAlerts()
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func fetchAlerts() async {
        guard let url = URL(string: "\(serverURL)/alerts") else {
            lastError = "Invalid server URL"
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(RenderAlertsResponse.self, from: data)
            alerts = decoded.alerts.map { r in
                PumpAlert(
                    id: r.id,
                    symbol: r.symbol,
                    priceChangePercent: r.priceChangePercent,
                    price: r.price,
                    volume: 0,
                    quoteVolume: 0,
                    detectedAt: Date(),
                    network: r.network,
                    baseTokenMint: r.baseTokenMint
                )
            }
            tokensTracked = decoded.tokensTracked ?? 0
            samplesTotal = decoded.samplesTotal ?? 0
            isConnected = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            isConnected = false
        }
    }
}

enum RenderConfig {
    static var serverURL: String {
        get { UserDefaults.standard.string(forKey: "render_pump_server_url") ?? "https://render-pump-server.onrender.com" }
        set { UserDefaults.standard.set(newValue, forKey: "render_pump_server_url") }
    }
}
