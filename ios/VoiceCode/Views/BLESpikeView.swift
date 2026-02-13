// BLESpikeView.swift
// UI for BLE spike: prove CoreBluetooth GATT works between iPhone and Mac.
// Disposable — will be reverted after spike.

import SwiftUI

struct BLESpikeView: View {
    @StateObject private var bleManager = BLEManager()
    @State private var messageText = ""

    var body: some View {
        Form {
            Section(header: Text("Connection")) {
                HStack {
                    connectionDot
                    Text(bleManager.connectionState.rawValue.capitalized)
                }

                if let peer = bleManager.connectedPeerName {
                    HStack {
                        Text("Peer")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(peer)
                    }
                }

                toggleButton
            }

            Section(header: Text("Messages")) {
                HStack {
                    Text("Received")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(bleManager.lastReceivedMessage ?? "—")
                        .lineLimit(3)
                }

                HStack {
                    Text("Sent")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(bleManager.lastSentMessage ?? "—")
                        .lineLimit(3)
                }
            }

            Section(header: Text("Send")) {
                TextField("Message", text: $messageText)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif

                Button("Send") {
                    guard !messageText.isEmpty else { return }
                    bleManager.sendMessage(messageText)
                    messageText = ""
                }
                .disabled(bleManager.connectionState != .connected || messageText.isEmpty)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("BLE Spike")
    }

    private var connectionDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 10, height: 10)
    }

    private var dotColor: Color {
        switch bleManager.connectionState {
        case .connected: return .green
        case .scanning, .advertising, .connecting: return .orange
        case .disconnected: return .red
        case .idle: return .gray
        }
    }

    @ViewBuilder
    private var toggleButton: some View {
        #if os(iOS)
        if bleManager.connectionState == .idle || bleManager.connectionState == .disconnected {
            Button("Start Advertising") {
                bleManager.startAdvertising()
            }
        } else {
            Button("Stop Advertising") {
                bleManager.stopAdvertising()
            }
        }
        #else
        if bleManager.connectionState == .idle || bleManager.connectionState == .disconnected {
            Button("Start Scanning") {
                bleManager.startScanning()
            }
        } else {
            Button("Disconnect") {
                bleManager.disconnect()
            }
        }
        #endif
    }
}
