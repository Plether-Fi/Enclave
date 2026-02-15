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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            WalledGardenWebView()
                .border(Color.red, width: 1)
        }
        .background(bgColor)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Menu {
                Button("New Wallet") {
                    do {
                        try EnclaveEngine.shared.generateKey()
                        log.info("New wallet created")
                    } catch {
                        log.error("Key generation failed: \(error.localizedDescription)")
                    }
                }
            } label: {
                Text("0xAbCd...VwXy")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.1))
                    .clipShape(Capsule())
            }

            Spacer()

            Button { log.info("Receive tapped") } label: {
                Label("Receive", systemImage: "arrow.down.circle")
            }

            Button { log.info("Send tapped") } label: {
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
