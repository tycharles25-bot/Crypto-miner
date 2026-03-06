//
//  CoinbaseWithdrawView.swift
//  Crypto miner
//

import SwiftUI

struct CoinbaseWithdrawView: View {
    @ObservedObject var coinbaseService: CoinbaseAccountService
    @State private var coin = "USDT"
    @State private var address = ""
    @State private var amount = ""
    @State private var isWithdrawing = false
    @State private var showSuccess = false
    @State private var withdrawError: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Withdraw to Wallet")
                .font(.headline)
                .foregroundColor(.white)
            
            TextField("Withdrawal address", text: $address)
                .textFieldStyle(.roundedBorder)
                #if !os(macOS)
                .autocapitalization(.none)
                #endif
            TextField("Amount", text: $amount)
                .textFieldStyle(.roundedBorder)
                #if !os(macOS)
                .keyboardType(.decimalPad)
                #endif
            
            if let err = withdrawError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            Button(action: performWithdraw) {
                if isWithdrawing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Withdraw")
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(coinbaseService.usdtBalance > 0 ? Color.orange : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(10)
            .disabled(isWithdrawing || (Double(amount) ?? 0) <= 0 || address.isEmpty || coinbaseService.usdtBalance <= 0)
        }
        .padding()
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        .cornerRadius(12)
        .alert("Withdrawal sent", isPresented: $showSuccess) {
            Button("OK") {
                amount = ""
                address = ""
                Task { await coinbaseService.refreshBalance() }
            }
        } message: {
            Text("Your withdrawal has been submitted.")
        }
    }
    
    private func performWithdraw() {
        guard let amt = Double(amount), amt > 0 else { return }
        isWithdrawing = true
        withdrawError = nil
        
        Task {
            do {
                try await coinbaseService.withdraw(coin: coin, address: address, amount: amt)
                showSuccess = true
            } catch CoinbaseAPIError.apiError(let msg) {
                withdrawError = msg
            } catch {
                withdrawError = error.localizedDescription
            }
            isWithdrawing = false
        }
    }
}
