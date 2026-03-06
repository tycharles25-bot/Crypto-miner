//
//  FiatRampInfoView.swift
//  Crypto miner
//

import SwiftUI

struct FiatRampInfoView: View {
    var onBuyWithCard: (() -> Void)?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundColor(.green)
                Text("Fiat On/Off Ramps")
                    .font(.headline)
                    .foregroundColor(.white)
            }
            
            Text("Deposit options")
                .font(.subheadline)
                .foregroundColor(.green)
            
            Text("Buy crypto with card. Use in Phantom/Uniswap for DEX swaps.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            #if os(iOS)
            if onBuyWithCard != nil {
                Button(action: { onBuyWithCard?() }) {
                    Label("Buy with Card", systemImage: "creditcard.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.2))
                        .foregroundColor(.blue)
                        .cornerRadius(10)
                }
            }
            #endif
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            VStack(alignment: .leading, spacing: 8) {
                rampRow(name: "Coinbase", fees: "Varies", note: "Crypto deposits/withdraw")
                rampRow(name: "Stripe", fees: "2.9% + 30¢", note: "Cards, Apple Pay")
            }
            .font(.caption)
        }
        .padding()
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        .cornerRadius(12)
    }
    
    private func rampRow(name: String, fees: String, note: String) -> some View {
        HStack {
            Text(name)
                .foregroundColor(.white)
            Text("•")
                .foregroundColor(.secondary)
            Text(fees)
                .foregroundColor(.secondary)
            Text("•")
                .foregroundColor(.secondary)
            Text(note)
                .foregroundColor(.secondary.opacity(0.9))
        }
    }
}
