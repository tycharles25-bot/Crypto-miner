//
//  WalletView.swift
//  Crypto miner
//

import SwiftUI

struct WalletView: View {
    @EnvironmentObject var wallet: WalletService
    @EnvironmentObject var dexTradeService: DEXTradeService
    @EnvironmentObject var solanaWallet: SolanaWalletService
    @EnvironmentObject var solanaBalance: SolanaBalanceService
    @State private var showDepositSheet = false
    @State private var showWithdrawSheet = false
    @State private var withdrawAmount = ""
    @State private var withdrawAddress = ""
    @State private var withdrawError: String?
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    balanceCard
                    depositWithdrawSection
                    investPerStockSection
                }
                .padding()
            }
            .background(Color(red: 0.06, green: 0.06, blue: 0.08))
            .navigationTitle("Wallet")
            .sheet(isPresented: $showDepositSheet) { depositSheet }
            .sheet(isPresented: $showWithdrawSheet) { withdrawSheet }
        }
    }
    
    private var balanceCard: some View {
        VStack(spacing: 12) {
            if solanaWallet.hasWallet, let pub = solanaWallet.publicKey {
                Text("SOL Balance")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(solBalanceFormatted)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)
                Text("Solana wallet")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.8))
                Button(action: { solanaBalance.fetchBalance(publicKey: pub) }) {
                    Text("Refresh")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            } else {
                Text("Connect wallet in Settings")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
        .cornerRadius(16)
        .onAppear {
            if let pub = solanaWallet.publicKey {
                Task { await solanaBalance.fetchBalance(publicKey: pub) }
            }
        }
    }
    
    private var solBalanceFormatted: String {
        guard let lamports = solanaBalance.balanceLamports else { return "—" }
        return String(format: "%.4f", Double(lamports) / 1_000_000_000)
    }
    
    private func statPill(label: String, value: Double, isProfit: Bool = false) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("$\(String(format: "%.2f", value))")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(isProfit ? (value >= 0 ? .green : .red) : .white)
        }
    }
    
    private var depositWithdrawSection: some View {
        HStack(spacing: 16) {
            Button(action: { showDepositSheet = true }) {
                Label("Deposit", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(solanaWallet.hasWallet ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                    .foregroundColor(solanaWallet.hasWallet ? .green : .gray)
                    .cornerRadius(12)
            }
            .disabled(!solanaWallet.hasWallet)
            Button(action: { showWithdrawSheet = true }) {
                Label("Withdraw", systemImage: "arrow.up.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(solanaWallet.hasWallet && (solanaBalance.balanceLamports ?? 0) > 0 ? Color.orange.opacity(0.2) : Color.gray.opacity(0.2))
                    .foregroundColor(solanaWallet.hasWallet && (solanaBalance.balanceLamports ?? 0) > 0 ? .orange : .gray)
                    .cornerRadius(12)
            }
            .disabled(!solanaWallet.hasWallet || (solanaBalance.balanceLamports ?? 0) == 0)
        }
    }
    
    private var investPerStockSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SOL per trade")
                .font(.headline)
                .foregroundColor(.white)
            
            if solanaWallet.hasWallet {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(String(format: "%.4f", Double(dexTradeService.solPerTradeLamports) / 1_000_000_000)) SOL")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Slider(value: Binding(
                        get: { Double(dexTradeService.solPerTradeLamports) / 1_000_000_000 },
                        set: { dexTradeService.solPerTradeLamports = UInt64($0 * 1_000_000_000) }
                    ), in: 0.0001...0.1, step: 0.0001)
                        .tint(.green)
                }
            } else {
                Text("Connect wallet in Settings")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
        .cornerRadius(12)
    }
    
    private var depositSheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let address = solanaWallet.publicKey {
                    Text("Send SOL to this address")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(address)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
                        .cornerRadius(8)
                    Button(action: {
                        #if os(iOS)
                        UIPasteboard.general.string = address
                        #elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                        #endif
                    }) {
                        Label("Copy address", systemImage: "doc.on.doc")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(12)
                    }
                } else {
                    Text("Connect wallet in Settings")
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .navigationTitle("Deposit SOL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showDepositSheet = false }
                }
            }
        }
    }
    
    private var withdrawSheet: some View {
        NavigationStack {
            Form {
                if let err = withdrawError {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                Section("Recipient address") {
                    TextField("Solana address", text: $withdrawAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Amount (SOL)") {
                    TextField("0.00", text: $withdrawAmount)
                        #if !os(macOS)
                        .keyboardType(.decimalPad)
                        #endif
                }
                if let lamports = solanaBalance.balanceLamports {
                    Text("Available: \(String(format: "%.4f", Double(lamports) / 1_000_000_000)) SOL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Withdraw SOL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showWithdrawSheet = false
                        withdrawAmount = ""
                        transactionNote = ""
                        withdrawError = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Withdraw") {
                        withdrawError = "Use Phantom or another wallet to send SOL"
                    }
                    .disabled(withdrawAmount.isEmpty || withdrawAddress.isEmpty)
                }
            }
        }
    }
    
}

#Preview {
    WalletView()
        .environmentObject(WalletService())
        .environmentObject(DEXTradeService())
        .environmentObject(SolanaWalletService())
        .environmentObject(SolanaBalanceService())
}
