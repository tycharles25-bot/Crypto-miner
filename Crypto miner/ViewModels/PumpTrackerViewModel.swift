//
//  PumpTrackerViewModel.swift
//  Crypto miner
//

import Foundation
import Combine

enum DataSource: String, CaseIterable {
    case binance = "Binance (CEX)"
    case fullUniverse = "Full Universe (DEX)"
}

@MainActor
class PumpTrackerViewModel: ObservableObject {
    @Published var isScanning = false
    @Published var alerts: [PumpAlert] = []
    @Published var minThreshold: Double = 20.0
    @Published var lastUpdate = Date()
    @Published var tickCount = 0
    @Published var dataSource: DataSource = .fullUniverse  // Always fullUniverse
    @Published var pumpDefinition: PumpDefinition = .hundredPerc10min
    
    let priceService = BinancePriceService()
    let geckoService = GeckoTerminalService()
    private var pumpDetector: PumpDetector?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        pumpDetector = PumpDetector(priceService: priceService)
        
        pumpDetector?.$alerts
            .sink { [weak self] binanceAlerts in
                guard let self else { return }
                if self.dataSource == .binance {
                    self.alerts = binanceAlerts
                }
            }
            .store(in: &cancellables)
        
        pumpDetector?.$minThreshold
            .assign(to: &$minThreshold)
        
        priceService.$lastUpdate
            .sink { [weak self] date in
                guard let self else { return }
                if self.dataSource == .binance { self.lastUpdate = date }
            }
            .store(in: &cancellables)
        
        priceService.$tickCount
            .sink { [weak self] count in
                guard let self else { return }
                if self.dataSource == .binance { self.tickCount = count }
            }
            .store(in: &cancellables)
        
        geckoService.$lastUpdate
            .sink { [weak self] date in
                guard let self else { return }
                if self.dataSource == .fullUniverse { self.lastUpdate = date }
            }
            .store(in: &cancellables)
        
        geckoService.$poolCount
            .sink { [weak self] count in
                guard let self else { return }
                if self.dataSource == .fullUniverse { self.tickCount = count }
            }
            .store(in: &cancellables)
    }
    
    func startScanning() {
        guard !isScanning else { return }
        isScanning = true
        
        switch dataSource {
        case .binance:
            priceService.connect()
        case .fullUniverse:
            let pct: Double
            switch pumpDefinition {
            case .consecutive3h, .consecutive3x20min, .single20min: pct = max(5, min(20, minThreshold))
            case .hundredPerc10min: pct = 100
            case .fiftyPerc20min: pct = 50
            case .threshold24h: pct = minThreshold
            }
            geckoService.startScanning(minThreshold: pct, pumpDefinition: pumpDefinition) { [weak self] newAlerts in
                self?.alerts = newAlerts
            }
        }
    }
    
    func stopScanning() {
        isScanning = false
        switch dataSource {
        case .binance:
            priceService.disconnect()
        case .fullUniverse:
            geckoService.stopScanning()
        }
    }
    
    func setThreshold(_ value: Double) {
        minThreshold = value
        pumpDetector?.minThreshold = value
    }
    
    func clearAlerts() {
        pumpDetector?.clearAlerts()
        if dataSource == .fullUniverse {
            alerts = []
        }
    }
    
    func setDataSource(_ source: DataSource) {
        let wasScanning = isScanning
        if wasScanning { stopScanning() }
        dataSource = source
        alerts = []
        if wasScanning { startScanning() }
    }
}
