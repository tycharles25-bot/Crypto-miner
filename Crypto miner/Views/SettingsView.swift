//
//  SettingsView.swift
//  Crypto miner
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var solanaWallet: SolanaWalletService
    @EnvironmentObject var dexTradeService: DEXTradeService
    @State private var showImportSheet = false
    @AppStorage("app_theme") private var appTheme = "system"
    @AppStorage("cashout_minutes") private var cashoutMinutes: Int = 5
    @AppStorage("sell_on_downturn") private var sellOnDownturn: Bool = false
    @AppStorage("downturn_percent") private var downturnPercent: Int = 15
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appTheme) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("DEX pump tracker. For Solana: connect wallet below for fully automatic swaps. Other chains open in browser.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
                
                Section("Trade History") {
                    if dexTradeService.tradeHistory.isEmpty {
                        Text("No trades yet")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(dexTradeService.tradeHistory) { record in
                            HStack {
                                Image(systemName: record.action == "Buy" ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                    .foregroundColor(record.action == "Buy" ? .green : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(record.action) \(record.symbol)")
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Text(record.date, style: .date)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                }
                
                Section("Solana Wallet (Auto-Swap)") {
                    if solanaWallet.hasWallet {
                        HStack {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Spacer()
                            Text(String(solanaWallet.publicKey?.prefix(8) ?? "") + "..." + String(solanaWallet.publicKey?.suffix(4) ?? ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Button("Disconnect", role: .destructive) {
                            solanaWallet.disconnect()
                        }
                    } else {
                        Button("Import Wallet") {
                            showImportSheet = true
                        }
                        Text("Import private key or seed phrase for fully automatic Solana swaps")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section("Auto-Trade") {
                    Stepper("Sell after \(cashoutMinutes) min", value: $cashoutMinutes, in: 1...1440, step: 5)
                    Text("Tokens auto-sell this many minutes after buy. Default: 5. Change takes effect for new buys.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Toggle("Sell on downturn", isOn: $sellOnDownturn)
                    if sellOnDownturn {
                        Stepper("Sell if price drops \(downturnPercent)% from peak", value: $downturnPercent, in: 5...50, step: 5)
                        Text("Sells immediately when price drops this much from the highest seen. Polls every 5 sec. Works alongside the timer.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section("Pump Server") {
                    TextField("Render server URL", text: Binding(
                        get: { RenderConfig.serverURL },
                        set: { RenderConfig.serverURL = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    Text("PumpApi server for pump detection")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Jupiter (Swaps)") {
                    TextField("API key (optional)", text: Binding(
                        get: { JupiterConfig.apiKey },
                        set: { JupiterConfig.apiKey = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Text("Optional. Without key: uses lite-api. With key from portal.jup.ag: higher rate limits.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Solana RPC (Helius recommended)") {
                    TextField("https://mainnet.helius-rpc.com/?api_key=YOUR_KEY", text: Binding(
                        get: { SolanaRPCConfig.rpcURL },
                        set: { SolanaRPCConfig.rpcURL = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    Text(SolanaRPCConfig.rpcURL.isEmpty ? "Using: Public RPC (rate-limited)" : "Using: \(SolanaRPCConfig.effectiveRPC.lowercased().contains("helius") ? "Helius" : "Custom RPC")")
                        .font(.caption)
                        .foregroundColor(SolanaRPCConfig.rpcURL.isEmpty ? .orange : .green)
                    Text("Required for reliable swaps. Free key at helius.dev")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section("Contribute Data") {
                    Toggle("Share data with server", isOn: Binding(
                        get: { ContributeConfig.isEnabled },
                        set: { ContributeConfig.isEnabled = $0 }
                    ))
                    TextField("Server URL", text: Binding(
                        get: { ContributeConfig.serverBaseURL },
                        set: { ContributeConfig.serverBaseURL = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    Text("When enabled, your app shares Gecko OHLCV data with your server. Each client = more coverage.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(isPresented: $showImportSheet) {
                SolanaWalletImportView(solanaWallet: solanaWallet, onDismiss: { showImportSheet = false })
            }
            .onAppear {
                if cashoutMinutes < 1 { cashoutMinutes = 5 }
                if downturnPercent < 5 || downturnPercent > 50 { downturnPercent = 15 }
            }
        }
    }
}

struct SolanaWalletImportView: View {
    @ObservedObject var solanaWallet: SolanaWalletService
    let onDismiss: () -> Void
    @State private var inputText = ""
    @State private var importError: String?
    @State private var isImporting = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Private key (base58) or seed phrase (12-24 words)", text: $inputText, axis: .vertical)
                        .lineLimit(3...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let err = importError {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                Section {
                    Text("Private key: Export from Phantom → Settings → Export Private Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Seed phrase: Your 12 or 24 recovery words")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Import Solana Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        importWallet()
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                }
            }
        }
    }
    
    private func importWallet() {
        importError = nil
        isImporting = true
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(separator: " ").map(String.init)
        
        Task { @MainActor in
            do {
                if words.count >= 12 && words.count <= 24 {
                    try await solanaWallet.importFromSeedPhrase(words)
                } else {
                    try solanaWallet.importFromPrivateKey(text)
                }
                onDismiss()
            } catch {
                importError = error.localizedDescription
            }
            isImporting = false
        }
    }
}
