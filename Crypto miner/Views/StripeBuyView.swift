//
//  StripeBuyView.swift
//  Crypto miner
//
//  Buy crypto with card via Stripe. iOS only.
//  Option 1: Payment Link - set stripePaymentLinkURL in Config, no backend needed
//  Option 2: PaymentSheet - set stripePublishableKey + stripeBackendURL, requires server
//

#if os(iOS)

import SwiftUI
import StripePaymentSheet

struct StripeBuyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var paymentSheet: PaymentSheet?
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Amount (USD)") {
                    TextField("0.00", text: $amount)
                        .keyboardType(.decimalPad)
                }
                
                if let err = errorMessage {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                    }
                }
                
                Section {
                    Button(action: startPayment) {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text(Config.stripePaymentLinkURL.isEmpty ? "Pay with Card" : "Open Payment Link")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .background(canPay ? Color.blue : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(!canPay || isLoading)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                
                Section {
                    Text("Create a Payment Link at dashboard.stripe.com/payment-links for instant setup. Or deploy a backend for custom amounts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Buy with Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                if !Config.stripePublishableKey.isEmpty {
                    StripeAPI.defaultPublishableKey = Config.stripePublishableKey
                }
            }
        }
    }
    
    private var canPay: Bool {
        if !Config.stripePaymentLinkURL.isEmpty {
            return true
        }
        if !Config.stripeBackendURL.isEmpty, !Config.stripePublishableKey.isEmpty {
            return (Double(amount) ?? 0) >= 1
        }
        return false
    }
    
    private func startPayment() {
        if !Config.stripePaymentLinkURL.isEmpty {
            if let url = URL(string: Config.stripePaymentLinkURL) {
                UIApplication.shared.open(url)
            }
            return
        }
        
        guard let amt = Double(amount), amt >= 1 else { return }
        guard !Config.stripeBackendURL.isEmpty else { return }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let clientSecret = try await fetchPaymentIntent(amount: amt)
                var config = PaymentSheet.Configuration()
                config.merchantDisplayName = "Crypto Miner"
                let sheet = PaymentSheet(paymentIntentClientSecret: clientSecret, configuration: config)
                await MainActor.run {
                    paymentSheet = sheet
                    isLoading = false
                    presentSheet(sheet)
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func presentSheet(_ sheet: PaymentSheet) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            errorMessage = "Could not present payment sheet"
            return
        }
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        sheet.present(from: topVC) { result in
            switch result {
            case .completed:
                dismiss()
            case .canceled:
                break
            case .failed(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func fetchPaymentIntent(amount: Double) async throws -> String {
        guard let url = URL(string: Config.stripeBackendURL) else {
            throw NSError(domain: "StripeBuyView", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid backend URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["amount": Int(amount * 100)]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let secret = json["clientSecret"] as? String else {
            throw NSError(domain: "StripeBuyView", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid backend response"])
        }
        return secret
    }
}

#endif
