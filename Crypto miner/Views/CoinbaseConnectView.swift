//
//  CoinbaseConnectView.swift
//  Crypto miner
//

import SwiftUI

struct CoinbaseConnectView: View {
    @ObservedObject var coinbaseService: CoinbaseAccountService
    @State private var apiKey = ""
    @State private var secretKey = ""
    @State private var passphrase = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "bitcoinsign.circle.fill")
                    .foregroundColor(.blue)
                Text("Coinbase")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                if coinbaseService.isConnected {
                    Text("Connected")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            
            if coinbaseService.isConnected {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("USDT Balance")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("$\(String(format: "%.2f", coinbaseService.usdtBalance))")
                            .font(.title3)
                            .foregroundColor(.white)
                    }
                    Spacer()
                    Button(action: {
                        Task { await coinbaseService.refreshBalance() }
                    }) {
                        if coinbaseService.isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(coinbaseService.isLoading)
                    Button("Disconnect") {
                        coinbaseService.disconnect()
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
                .padding()
                .background(Color(red: 0.1, green: 0.1, blue: 0.12))
                .cornerRadius(10)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect your Coinbase Exchange API. Create keys at exchange.coinbase.com/settings/api. Enable View and Transfer permissions.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        #if !os(macOS)
                        .autocapitalization(.none)
                        #endif
                    TextField("Secret Key", text: $secretKey)
                        .textFieldStyle(.roundedBorder)
                        #if !os(macOS)
                        .autocapitalization(.none)
                        #endif
                    TextField("Passphrase", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                        #if !os(macOS)
                        .autocapitalization(.none)
                        #endif
                    Button("Connect") {
                        coinbaseService.connect(apiKey: apiKey, secretKey: secretKey, passphrase: passphrase)
                        apiKey = ""
                        secretKey = ""
                        passphrase = ""
                    }
                    .disabled(apiKey.isEmpty || secretKey.isEmpty || passphrase.isEmpty)
                }
                .padding()
                .background(Color(red: 0.1, green: 0.1, blue: 0.12))
                .cornerRadius(10)
            }
            
            if let err = coinbaseService.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding()
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        .cornerRadius(12)
    }
}
