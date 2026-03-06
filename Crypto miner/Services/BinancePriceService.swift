//
//  BinancePriceService.swift
//  Crypto miner
//
//  Connects to Binance WebSocket for real-time price updates (~1 sec)
//

import Foundation
import Combine

@MainActor
class BinancePriceService: ObservableObject {
    @Published var isConnected = false
    @Published var lastUpdate = Date()
    @Published var tickCount = 0
    
    /// Latest price per symbol
    private(set) var prices: [String: PriceTick] = [:]
    
    /// Stream of new ticks for pump detection
    let tickPublisher = PassthroughSubject<PriceTick, Never>()
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private let url = URL(string: "wss://stream.binance.com:9443/stream?streams=!ticker@arr")!
    
    func connect() {
        guard webSocketTask == nil else { return }
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        isConnected = true
        receiveMessage()
        startPingTimer()
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        pingTimer?.invalidate()
        pingTimer = nil
        isConnected = false
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self?.processMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self?.processMessage(text)
                        }
                    @unknown default:
                        break
                    }
                case .failure(let error):
                    print("WebSocket error: \(error)")
                    self?.isConnected = false
                    return
                }
                self?.receiveMessage()
            }
        }
    }
    
    private func processMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        
        do {
            let tickers: [BinanceTickerData]
            if let response = try? JSONDecoder().decode(BinanceTickerResponse.self, from: data), let arr = response.data {
                tickers = arr
            } else if let arr = try? JSONDecoder().decode([BinanceTickerData].self, from: data) {
                tickers = arr
            } else {
                return
            }
            for ticker in tickers {
                let tick = ticker.toPriceTick()
                prices[ticker.s] = tick
                tickPublisher.send(tick)
            }
            tickCount += 1
            lastUpdate = Date()
        } catch {
            // Fallback: raw array (some streams send array directly)
            if let tickers = try? JSONDecoder().decode([BinanceTickerData].self, from: data) {
                for ticker in tickers {
                    let tick = ticker.toPriceTick()
                    prices[ticker.s] = tick
                    tickPublisher.send(tick)
                }
                tickCount += 1
                lastUpdate = Date()
            }
        }
    }
    
    private func startPingTimer() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.webSocketTask?.sendPing { _ in }
            }
        }
        RunLoop.current.add(pingTimer!, forMode: .common)
    }
    
    func price(for symbol: String) -> PriceTick? {
        prices[symbol]
    }
}
