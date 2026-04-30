//
//  ContentView.swift
//  PulseIQ
//
//  Created by dima on 24-04-2026.
//

import SwiftUI
import MultipeerConnectivity

struct ContentView: View {
    var body: some View {
        #if os(macOS)
        DashboardView()
        #else
        IOSBridgeView()
        #endif
    }
}

#if os(iOS)
struct IOSBridgeView: View {
    @StateObject private var healthKitManager = HealthKitManager.shared
    @EnvironmentObject var syncManager: SyncManager
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(syncManager.isConnected ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                    .frame(width: 140, height: 140)
                
                if syncManager.isSyncing {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(syncManager.isConnected ? .green : .orange)
                } else {
                    Image(systemName: syncManager.isConnected ? "checkmark.circle.fill" : (syncManager.nearbyPeers.isEmpty ? "antenna.radiowaves.left.and.right" : "macmini.fill"))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .foregroundColor(syncManager.isConnected ? .green : (syncManager.nearbyPeers.isEmpty ? .orange : .blue))
                        .symbolEffect(.pulse, options: .repeating, isActive: !syncManager.isConnected)
                        .onTapGesture {
                            syncManager.reset()
                        }
                }
            }
            
            VStack(spacing: 8) {
                Text(syncManager.isConnected ? "Connected to Mac" : (syncManager.nearbyPeers.isEmpty ? "Searching for Mac…" : "Mac Found!"))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                
                if !syncManager.isConnected && !syncManager.nearbyPeers.isEmpty {
                    Text("Found: \(syncManager.nearbyPeers.first?.displayName ?? "Unknown")")
                        .font(.headline)
                        .foregroundColor(.orange)
                        .padding(.bottom, 4)
                }
                
                if syncManager.isConnected {
                    ForEach(syncManager.connectedPeers, id: \.self) { peer in
                        HStack(spacing: 6) {
                            Image(systemName: "laptopcomputer")
                                .foregroundColor(.green)
                            Text(peer.displayName)
                                .foregroundColor(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
                
                Text(healthKitManager.isAuthorized
                     ? (syncManager.isConnected
                        ? "Syncing HealthKit data to macOS via local network."
                        : (syncManager.nearbyPeers.isEmpty 
                           ? "Both devices must be on the **same WiFi network**.\nUSB cable alone is not enough for sync."
                           : "Attempting to establish a secure connection..."))
                     : "PulseIQ requires HealthKit access to sync your metrics.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 4)
            }
            
            if !healthKitManager.isAuthorized {
                Button(action: {
                    healthKitManager.requestAuthorization { success in
                        if success {
                            healthKitManager.startObserving()
                        }
                    }
                }) {
                    Text("Grant Health Access")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 40)
                .padding(.top, 20)
            }
            
            Spacer()
            
            if !syncManager.isConnected && healthKitManager.isAuthorized {
                VStack(spacing: 6) {
                    Text("Troubleshooting")
                        .font(.caption.bold())
                    Text("• Make sure the macOS PulseIQ app is running\n• Both devices must be on the same WiFi\n• Allow Local Network access when prompted")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal, 30)
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
        .onAppear {
            healthKitManager.checkAuthorizationStatus()
        }
        .onChange(of: syncManager.isConnected) { oldValue, connected in
            if connected {
                healthKitManager.forceSyncAll()
            }
        }
    }
}
#endif
