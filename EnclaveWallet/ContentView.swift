//
//  ContentView.swift
//  EnclaveWallet
//
//  Created by Stanisław Wasiutyński on 15/02/2026.
//

import SwiftUI
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "UI")

struct ContentView: View {
    private let bgColor = Color.white

    @State private var wallets: [Wallet] = EnclaveEngine.shared.wallets
    @State private var selectedAddress: String = EnclaveEngine.shared.currentWallet?.displayAddress ?? "No Wallet"

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            WalledGardenWebView()
                .border(Color.red, width: 1)
        }
        .background(bgColor)
    }

    private func refreshWallets() {
        wallets = EnclaveEngine.shared.wallets
        selectedAddress = EnclaveEngine.shared.currentWallet?.displayAddress ?? "No Wallet"
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(wallets, id: \.index) { wallet in
                    Button(wallet.displayAddress) {
                        EnclaveEngine.shared.selectWallet(at: wallet.index)
                        refreshWallets()
                    }
                }

                if !wallets.isEmpty { Divider() }

                Button("New Wallet") {
                    do {
                        try EnclaveEngine.shared.generateKey()
                        refreshWallets()
                    } catch {
                        log.error("Key generation failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } label: {
                Text(selectedAddress)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.1))
                    .clipShape(Capsule())
            }

            Spacer()

            Button { log.notice("Receive tapped") } label: {
                Label("Receive", systemImage: "arrow.down.circle")
            }

            Button { log.notice("Send tapped") } label: {
                Label("Send", systemImage: "arrow.up.circle")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.black)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(bgColor)
    }
}
