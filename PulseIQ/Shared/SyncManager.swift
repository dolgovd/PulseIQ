import Foundation
import MultipeerConnectivity
import CoreData
import Combine

#if os(iOS)
import UIKit
#endif

public class SyncManager: NSObject, ObservableObject {
    public static let shared = SyncManager()
    
    private let serviceType = "piq"
    
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!
    private var myPeerId: MCPeerID!
    
    @Published public var isConnected = false
    @Published public var isSyncing = false
    @Published public var connectedPeers: [MCPeerID] = []
    @Published public var nearbyPeers: [MCPeerID] = []
    
    private var samplesBuffer: [SyncPayload.SampleDto] = []
    private var saveTimer: Timer?
    private let saveBatchSize = 2000
    
    private override init() {
        super.init()
        // Force clear to resolve potential corruption in PeerID identity
        // UserDefaults.standard.removeObject(forKey: "PulseIQ_PeerID_v2") 
        setupPeer()
        setupSession()
        start()
    }
    
    private func setupPeer() {
        if let data = UserDefaults.standard.data(forKey: "PulseIQ_PeerID_v2"),
           let peerId = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data) {
            self.myPeerId = peerId
            print("SyncManager: Reusing persisted PeerID: \(peerId.displayName)")
        } else {
            #if os(macOS)
            let displayName = Host.current().localizedName ?? "Mac"
            #else
            let displayName = UIDevice.current.name
            #endif
            
            let peerId = MCPeerID(displayName: displayName)
            self.myPeerId = peerId
            
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: peerId, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: "PulseIQ_PeerID_v2")
            }
            print("SyncManager: Created new PeerID: \(displayName)")
        }
    }
    
    private func setupSession() {
        // Using .none encryption to eliminate handshake failures in local networks
        self.session = MCSession(peer: myPeerId, securityIdentity: nil, encryptionPreference: .none)
        self.session.delegate = self
        
        self.advertiser = MCNearbyServiceAdvertiser(peer: myPeerId, discoveryInfo: ["role": "pulse-iq-node"], serviceType: serviceType)
        self.advertiser.delegate = self
        
        self.browser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: serviceType)
        self.browser.delegate = self
    }
    
    public func start() {
        print("SyncManager: Starting Multipeer services (Type: \(serviceType))...")
        self.advertiser.startAdvertisingPeer()
        self.browser.startBrowsingForPeers()
    }
    
    public func stop() {
        print("SyncManager: Stopping Multipeer services...")
        self.advertiser?.stopAdvertisingPeer()
        self.browser?.stopBrowsingForPeers()
        self.advertiser = nil
        self.browser = nil
        self.session?.disconnect()
    }
    
    public func reset() {
        print("SyncManager: Manual Reset triggered...")
        stop()
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectedPeers = []
            self.nearbyPeers = []
        }
        
        // Small delay to let OS cleanup Bonjour cache
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.setupSession()
            self.start()
        }
    }
    
    public func send(samples: [HealthSample]) {
        let connectedPeers = session.connectedPeers
        guard !connectedPeers.isEmpty else { 
            print("SyncManager: Skipping send - no connected peers.")
            return 
        }
        
        let dtos = samples.map { sample in
            SyncPayload.SampleDto(
                id: sample.id,
                type: sample.type,
                value: sample.value,
                startDate: sample.startDate,
                endDate: sample.endDate
            )
        }
        
        let payload = SyncPayload(samples: dtos)
        do {
            let data = try JSONEncoder().encode(payload)
            try session.send(data, toPeers: connectedPeers, with: .reliable)
            print("SyncManager: Sent \(dtos.count) samples to \(connectedPeers.count) peers.")
        } catch {
            print("SyncManager: Error sending samples: \(error.localizedDescription)")
        }
    }
}

// MARK: - MCSessionDelegate
extension SyncManager: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let stateString: String
        switch state {
        case .connected: stateString = "Connected"
        case .connecting: stateString = "Connecting"
        case .notConnected: stateString = "Not Connected"
        @unknown default: stateString = "Unknown"
        }
        
        print("SyncManager: Peer \(peerID.displayName) changed state to: \(stateString)")
        
        DispatchQueue.main.async {
            self.connectedPeers = session.connectedPeers
            self.isConnected = !session.connectedPeers.isEmpty
            
            // If connected, remove from nearby
            if state == .connected {
                self.nearbyPeers.removeAll { $0 == peerID }
            }
        }
    }
    
    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        do {
            let payload = try JSONDecoder().decode(SyncPayload.self, from: data)
            
            // Handle Commands
            if let command = payload.command {
                switch command {
                case .requestFullSync:
                    print("Received RequestFullSync from \(peerID.displayName)")
                    #if os(iOS)
                    // On iOS, trigger the full sync and send back data
                    DispatchQueue.main.async {
                        // Assuming HealthKitManager is accessible or we use a notification
                        NotificationCenter.default.post(name: Notification.Name("TriggerFullSync"), object: nil)
                    }
                    #endif
                }
            }
            
            // Handle Samples
            if let samples = payload.samples, !samples.isEmpty {
                DispatchQueue.main.async {
                    self.isSyncing = true
                    self.samplesBuffer.append(contentsOf: samples)
                    
                    // Reset timer to save after a short period of inactivity or when buffer is large
                    self.saveTimer?.invalidate()
                    if self.samplesBuffer.count >= self.saveBatchSize {
                        self.processBuffer()
                    } else {
                        self.saveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                            self?.processBuffer()
                        }
                    }
                }
            }
        } catch {
            print("SyncManager: Error decoding payload: \(error)")
        }
    }
    
    private func processBuffer() {
        guard !samplesBuffer.isEmpty else {
            self.isSyncing = false
            return
        }
        
        let batch = samplesBuffer
        samplesBuffer.removeAll()
        
        print("SyncManager: Batch processing \(batch.count) samples...")
        
        let context = CoreDataManager.shared.container.newBackgroundContext()
        context.perform {
            for dto in batch {
                let fetch: NSFetchRequest<HealthSample> = NSFetchRequest(entityName: "HealthSample")
                fetch.predicate = NSPredicate(format: "id == %@", dto.id as CVarArg)
                
                if let existing = try? context.fetch(fetch).first {
                    existing.value = dto.value
                } else {
                    let sample = HealthSample(context: context)
                    sample.id = dto.id
                    sample.type = dto.type
                    sample.value = dto.value
                    sample.startDate = dto.startDate
                    sample.endDate = dto.endDate
                }
            }
            
            if context.hasChanges {
                try? context.save()
                print("SyncManager: Batch saved successfully.")
            }
            
            DispatchQueue.main.async {
                // If more samples arrived during processing, don't stop syncing yet
                if self.samplesBuffer.isEmpty {
                    self.isSyncing = false
                }
            }
        }
    }
    
    public func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        // Always accept certificates to avoid handshake hangs in local development
        print("SyncManager: Received certificate from \(peerID.displayName), accepting...")
        certificateHandler(true)
    }
    
    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension SyncManager: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("SyncManager: >>> RECEIVED INVITATION from \(peerID.displayName)")
        print("SyncManager: Accepting invitation and providing current session...")
        invitationHandler(true, self.session)
    }
    
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("SyncManager: Advertiser failed to start: \(error.localizedDescription)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension SyncManager: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        print("SyncManager: Found peer (\(peerID.displayName))")
        
        // Don't invite ourselves
        guard peerID != myPeerId else { return }
        
        // Tie-breaker: Both devices are browsing and advertising.
        // To avoid race conditions, only the peer with the lexicographically smaller display name initiates.
        let isInviter = myPeerId.displayName < peerID.displayName
        
        if isInviter {
            if session.connectedPeers.contains(peerID) {
                print("SyncManager: Already connected to \(peerID.displayName).")
                return
            }
            
            // Adding a small delay to ensure the other peer's advertiser is fully ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                print("SyncManager: I am the inviter. Inviting \(peerID.displayName)...")
                self.browser?.invitePeer(peerID, to: self.session, withContext: nil, timeout: 30)
            }
        } else {
            print("SyncManager: I am the invitee. Waiting for \(peerID.displayName) to invite me...")
        }
        
        DispatchQueue.main.async {
            if !self.nearbyPeers.contains(peerID) {
                self.nearbyPeers.append(peerID)
            }
        }
    }
    
    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("SyncManager: Lost peer \(peerID.displayName)")
        DispatchQueue.main.async {
            self.nearbyPeers.removeAll { $0 == peerID }
        }
    }
    
    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("SyncManager: Browser failed to start: \(error.localizedDescription)")
    }
}

// MARK: - Sync Payload DTO
struct SyncPayload: Codable {
    enum Command: String, Codable {
        case requestFullSync
    }
    
    struct SampleDto: Codable {
        let id: UUID
        let type: String
        let value: Double
        let startDate: Date
        let endDate: Date
    }
    
    let command: Command?
    let samples: [SampleDto]?
    
    init(command: Command? = nil, samples: [SampleDto]? = nil) {
        self.command = command
        self.samples = samples
    }
}

extension SyncManager {
    public func requestFullSync() {
        guard !session.connectedPeers.isEmpty else {
            print("Cannot request sync: No connected peers.")
            return
        }
        
        let payload = SyncPayload(command: .requestFullSync)
        do {
            let data = try JSONEncoder().encode(payload)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            print("Sent Full Sync request to peers.")
        } catch {
            print("Failed to send sync request: \(error)")
        }
    }
}
