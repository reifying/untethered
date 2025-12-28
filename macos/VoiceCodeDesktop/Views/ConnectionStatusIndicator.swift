// ConnectionStatusIndicator.swift
// Reusable connection status indicator per Appendix J.4

import SwiftUI
import VoiceCodeShared

// MARK: - ConnectionStatusIndicator

/// A reusable connection status indicator that displays an icon with appropriate styling
/// based on the current connection state. Follows Appendix J.4 specifications.
///
/// Icon States per J.4:
/// - Connected: `waveform` (green)
/// - Disconnected: `waveform.slash` (red)
/// - Reconnecting: `arrow.trianglehead.2.clockwise` (orange, animated)
/// - Connecting/Authenticating: `waveform` (orange, pulsing)
/// - Failed: `waveform.slash` (red)
struct ConnectionStatusIndicator: View {
    let connectionState: ConnectionState
    var size: CGFloat = 16

    /// Animation state for pulsing/rotating effects
    @State private var isAnimating = false

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: size))
            .foregroundColor(iconColor)
            .symbolEffect(.pulse, options: .repeating, isActive: shouldPulse)
            .rotationEffect(shouldRotate ? .degrees(isAnimating ? 360 : 0) : .zero)
            .animation(
                shouldRotate ? .linear(duration: 1.0).repeatForever(autoreverses: false) : .default,
                value: isAnimating
            )
            .onAppear {
                isAnimating = shouldRotate
            }
            .onChange(of: connectionState) {
                isAnimating = shouldRotate
            }
            .accessibilityLabel(accessibilityLabel)
    }

    /// Icon name based on connection state per J.4
    private var iconName: String {
        switch connectionState {
        case .connected:
            return "waveform"
        case .disconnected, .failed:
            return "waveform.slash"
        case .reconnecting:
            return "arrow.trianglehead.2.clockwise"
        case .connecting, .authenticating:
            return "waveform"
        }
    }

    /// Icon color based on connection state
    private var iconColor: Color {
        switch connectionState {
        case .connected:
            return .green
        case .connecting, .authenticating, .reconnecting:
            return .orange
        case .disconnected, .failed:
            return .red
        }
    }

    /// Whether the icon should pulse (for connecting/authenticating states)
    private var shouldPulse: Bool {
        switch connectionState {
        case .connecting, .authenticating:
            return true
        default:
            return false
        }
    }

    /// Whether the icon should rotate (for reconnecting state)
    private var shouldRotate: Bool {
        connectionState == .reconnecting
    }

    /// Accessibility label for the indicator
    private var accessibilityLabel: String {
        switch connectionState {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .authenticating:
            return "Authenticating"
        case .reconnecting:
            return "Reconnecting"
        case .disconnected:
            return "Disconnected"
        case .failed:
            return "Connection failed"
        }
    }
}

// MARK: - ConnectionStatusDot

/// A simple colored dot indicator for compact displays (e.g., sidebar footer)
struct ConnectionStatusDot: View {
    let connectionState: ConnectionState
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: size, height: size)
            .accessibilityLabel(accessibilityLabel)
    }

    private var dotColor: Color {
        switch connectionState {
        case .connected:
            return .green
        case .connecting, .authenticating, .reconnecting:
            return .orange
        case .disconnected, .failed:
            return .red
        }
    }

    private var accessibilityLabel: String {
        switch connectionState {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .authenticating:
            return "Authenticating"
        case .reconnecting:
            return "Reconnecting"
        case .disconnected:
            return "Disconnected"
        case .failed:
            return "Connection failed"
        }
    }
}

// MARK: - ConnectionStatusText

/// Provides human-readable text for connection states
struct ConnectionStatusText: View {
    let connectionState: ConnectionState
    var showDetails: Bool = false
    var serverURL: String = ""
    var serverPort: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(statusText)
                .font(.caption)
                .foregroundColor(.primary)

            if showDetails && !serverURL.isEmpty {
                Text("\(serverURL):\(serverPort)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statusText: String {
        switch connectionState {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .authenticating:
            return "Authenticating..."
        case .reconnecting:
            return "Reconnecting..."
        case .disconnected:
            return "Disconnected"
        case .failed:
            return "Connection Failed"
        }
    }
}

// MARK: - Previews

#Preview("All States") {
    VStack(spacing: 20) {
        ForEach(ConnectionState.allCases, id: \.self) { state in
            HStack(spacing: 12) {
                ConnectionStatusIndicator(connectionState: state, size: 20)
                ConnectionStatusDot(connectionState: state)
                ConnectionStatusText(connectionState: state, showDetails: true, serverURL: "localhost", serverPort: "8080")
                Spacer()
            }
            .padding(.horizontal)
        }
    }
    .padding()
    .frame(width: 300)
}
