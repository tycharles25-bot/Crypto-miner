//
//  PumpDetector.swift
//  Crypto miner
//
//  Scans for pumps: price changes > threshold, statistical outliers
//

import Foundation
import Combine

@MainActor
class PumpDetector: ObservableObject {
    @Published var alerts: [PumpAlert] = []
    @Published var minThreshold: Double = 20.0
    @Published var showOutliersOnly: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    private var recentTicks: [String: [PriceTick]] = [:]
    private let maxHistory = 60
    
    init(priceService: BinancePriceService) {
        priceService.tickPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] tick in
                self?.processTick(tick)
            }
            .store(in: &cancellables)
    }
    
    private func processTick(_ tick: PriceTick) {
        // Add to history
        if recentTicks[tick.symbol] == nil {
            recentTicks[tick.symbol] = []
        }
        recentTicks[tick.symbol]?.append(tick)
        if recentTicks[tick.symbol]!.count > maxHistory {
            recentTicks[tick.symbol]?.removeFirst()
        }
        
        // Check if pump
        let change = tick.priceChangePercent
        guard change >= minThreshold else { return }
        
        let alert = PumpAlert(
            id: tick.id,
            symbol: tick.symbol,
            priceChangePercent: change,
            price: tick.price,
            volume: tick.volume,
            quoteVolume: tick.quoteVolume,
            detectedAt: Date(),
            network: nil,
            baseTokenMint: nil
        )
        
        // Avoid duplicates: skip if same symbol alerted in last 2 minutes
        let twoMinutesAgo = Date().addingTimeInterval(-120)
        if alerts.contains(where: { $0.symbol == tick.symbol && $0.detectedAt > twoMinutesAgo }) {
            return
        }
        
        alerts.insert(alert, at: 0)
        if alerts.count > 100 {
            alerts.removeLast()
        }
    }
    
    func clearAlerts() {
        alerts.removeAll()
    }
}
