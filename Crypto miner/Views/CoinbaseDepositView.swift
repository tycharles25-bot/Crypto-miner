//
//  CoinbaseDepositView.swift
//  Crypto miner
//

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct CoinbaseDepositView: View {
    @ObservedObject var coinbaseService: CoinbaseAccountService
    @State private var copied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Deposit USDT")
                .font(.headline)
                .foregroundColor(.white)
            
            Text("Send USDT to your Coinbase account. Get a deposit address below.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Button("Get Deposit Address") {
                Task { await coinbaseService.fetchDepositAddress() }
            }
            .disabled(coinbaseService.isLoading)
            
            if let address = coinbaseService.depositAddress {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your USDT address:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(address)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Button(action: copyAddress) {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .disabled(copied)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.1, green: 0.1, blue: 0.12))
                .cornerRadius(10)
            }
        }
        .padding()
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        .cornerRadius(12)
    }
    
    private func copyAddress() {
        guard let addr = coinbaseService.depositAddress else { return }
        #if os(iOS)
        UIPasteboard.general.string = addr
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(addr, forType: .string)
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}
