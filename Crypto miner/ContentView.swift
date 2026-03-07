//
//  ContentView.swift
//  Crypto miner
//

import SwiftUI

struct ContentView: View {
    @AppStorage("app_theme") private var appTheme = "system" // system, light, dark
    var body: some View {
        TabView {
            PumpTrackerView()
                .tabItem {
                    Label("Pumps", systemImage: "chart.line.uptrend.xyaxis")
                }
            WalletView()
                .tabItem {
                    Label("Wallet", systemImage: "wallet.pass.fill")
                }
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .preferredColorScheme(themeColorScheme)
    }
    
    private var themeColorScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

struct PumpTrackerView: View {
    @EnvironmentObject var dexTradeService: DEXTradeService
    @EnvironmentObject var solanaWallet: SolanaWalletService
    @Environment(SolanaBalanceService.self) var solanaBalance
    @EnvironmentObject var jupiterSwap: JupiterSwapService
    @EnvironmentObject var renderPump: RenderPumpService
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let err = dexTradeService.errorMessage {
                    HStack {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .lineLimit(3)
                        Spacer()
                        Button("Dismiss") { dexTradeService.errorMessage = nil }
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.2))
                }
                autoTradeToggle
                lastTradedSection
                pumpAlertsSection
            }
            .navigationTitle("Pump Tracker")
            .background(Color(red: 0.06, green: 0.06, blue: 0.08))
            .onAppear {
                renderPump.startPolling()
            }
            .onDisappear {
                renderPump.stopPolling()
            }
            .onChange(of: renderPump.alerts.first?.baseTokenMint ?? "") { _, _ in
                guard dexTradeService.isEnabled else { return }
                guard let newest = renderPump.alerts.first,
                      newest.network == "solana",
                      newest.baseTokenMint != nil else { return }
                let cashoutSecs: TimeInterval = 3600
                Task {
                    if let pub = solanaWallet.publicKey {
                        await solanaBalance.fetchBalance(publicKey: pub)
                    }
                    dexTradeService.tryTrade(
                        pump: newest,
                        cashoutAfterSeconds: cashoutSecs,
                        solanaWallet: solanaWallet,
                        solanaBalance: solanaBalance,
                        jupiterSwap: jupiterSwap
                    )
                }
            }
        }
    }
    
    private var autoTradeToggle: some View {
        HStack {
            Text("Auto-trade")
                .font(.headline)
                .foregroundColor(.white)
            Spacer()
            Toggle("", isOn: $dexTradeService.isEnabled)
                .labelsHidden()
                .tint(.green)
        }
        .padding()
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
    }
    
    private var lastTradedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last 10 attempts")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal)
            
            if dexTradeService.tradeHistory.isEmpty {
                Text("No activity yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(dexTradeService.tradeHistory) { record in
                            TradedTokenChip(
                                symbol: record.symbol,
                                action: record.action,
                                date: record.date
                            )
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)
            }
        }
    }
    
    private var pumpAlertsSection: some View {
        VStack(spacing: 0) {
            if dexTradeService.pendingCashouts.isEmpty && renderPump.alerts.isEmpty {
                Spacer()
                if let err = renderPump.lastError {
                    VStack(spacing: 8) {
                        Text(err)
                            .font(.subheadline)
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                        Button("Retry") { Task { await renderPump.fetchAlerts() } }
                            .font(.subheadline)
                            .foregroundColor(.green)
                    }
                    .padding()
                } else if !renderPump.isConnected {
                    ProgressView("Connecting to pump server...")
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No pumps yet")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    if renderPump.tokensTracked > 0 {
                        Text("Tracking \(renderPump.tokensTracked) tokens — need 50%+ gain in 10 min")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    Text("Server: \(renderPump.serverURL)")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.8))
                }
                Spacer()
            } else {
                if !dexTradeService.pendingCashouts.isEmpty {
                    Text("Currently trading")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    
                    List {
                        ForEach(dexTradeService.pendingCashouts, id: \.pump.id) { item in
                            HStack {
                                Text(item.pump.displaySymbol)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Spacer()
                                CashoutCountdownRow(
                                    pump: item.pump,
                                    depositAt: item.depositAt,
                                    cashoutAfterSeconds: item.cashoutAfterSeconds
                                )
                            }
                            .listRowBackground(Color(red: 0.1, green: 0.1, blue: 0.12))
                            .listRowSeparatorTint(.white.opacity(0.1))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
                
                if !renderPump.alerts.isEmpty {
                    Text("Pump alerts")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    
                    List {
                        ForEach(renderPump.alerts.prefix(20)) { pump in
                            HStack {
                                Text(pump.displaySymbol)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Spacer()
                                Text("+\(Int(pump.priceChangePercent))%")
                                    .font(.subheadline)
                                    .foregroundColor(.green)
                            }
                            .listRowBackground(Color(red: 0.1, green: 0.1, blue: 0.12))
                            .listRowSeparatorTint(.white.opacity(0.1))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .padding()
    }
}

struct TradedTokenChip: View {
    let symbol: String
    let action: String
    let date: Date

    private var iconName: String {
        switch action {
        case "Buy": return "arrow.down.circle.fill"
        case "Sell": return "arrow.up.circle.fill"
        case "Buy failed", "Sell failed": return "xmark.circle.fill"
        default: return "questionmark.circle"
        }
    }

    private var iconColor: Color {
        switch action {
        case "Buy": return .green
        case "Sell": return .orange
        case "Buy failed", "Sell failed": return .red
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.caption)
                    .foregroundColor(iconColor)
                Text(symbol)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                Text(action)
                    .font(.caption2)
                    .foregroundColor(iconColor)
            }
            Text(date, style: .relative)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
        .cornerRadius(10)
    }
}

struct CashoutCountdownRow: View {
    let pump: PumpAlert
    let depositAt: Date
    let cashoutAfterSeconds: TimeInterval
    
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let elapsed = Date().timeIntervalSince(depositAt)
            let remaining = max(0, cashoutAfterSeconds - elapsed)
            let mins = Int(remaining) / 60
            let secs = Int(remaining) % 60
            Text("Cash out in \(mins)m \(secs)s")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WalletService())
        .environmentObject(DEXTradeService())
        .environmentObject(SolanaWalletService())
        .environment(SolanaBalanceService())
        .environmentObject(JupiterSwapService())
        .environmentObject(RenderPumpService())
}
