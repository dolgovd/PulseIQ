import Foundation
import MultipeerConnectivity
import CoreData
import Combine

#if os(iOS)
import UIKit
#endif

public class SyncManager: NSObject, ObservableObject {
    public static let shared = SyncManager()
    
    private let serviceType = "pulseiq-sync"
    
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!
    
    @Published public var isConnected = false
    @Published public var connectedPeers: [MCPeerID] = []
    @Published public var nearbyPeers: [MCPeerID] = [] // Peers found but not yet connected
    
    private override init() {
        super.init()
        
        #if os(macOS)
        let displayName = Host.current().localizedName ?? "Mac"
        #else
        let displayName = UIDevice.current.name
        #endif
        
        print("Initializing SyncManager with display name: \(displayName)")
        
        let peerId = MCPeerID(displayName: displayName)
        self.session = MCSession(peer: peerId, securityIdentity: nil, encryptionPreference: .required)
        self.session.delegate = self
        
        self.advertiser = MCNearbyServiceAdvertiser(peer: peerId, discoveryInfo: nil, serviceType: serviceType)
        self.advertiser.delegate = self
        
        self.browser = MCNearbyServiceBrowser(peer: peerId, serviceType: serviceType)
        self.browser.delegate = self
        
        start()
    }
    
    public func start() {
        print("Starting Multipeer services (Type: \(serviceType))...")
        self.advertiser.startAdvertisingPeer()
        self.browser.startBrowsingForPeers()
    }
    
    public func stop() {
        print("Stopping Multipeer services...")
        self.advertiser.stopAdvertisingPeer()
        self.browser.stopBrowsingForPeers()
        self.session.disconnect()
    }
    
    public func reset() {
        print("Resetting Multipeer Session...")
        stop()
        
        let peerId = session.myPeerID
        self.session = MCSession(peer: peerId, securityIdentity: nil, encryptionPreference: .optional)
        self.session.delegate = self
        
        self.advertiser = MCNearbyServiceAdvertiser(peer: peerId, discoveryInfo: ["role": "pulse-iq"], serviceType: serviceType)
        self.advertiser.delegate = self
        
        self.browser = MCNearbyServiceBrowser(peer: peerId, serviceType: serviceType)
        self.browser.delegate = self
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectedPeers = []
            self.nearbyPeers = []
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.start()
        }
    }
    
    public func send(samples: [HealthSample]) {
        let connectedPeers = session.connectedPeers
        guard !connectedPeers.isEmpty else { 
            print("Skipping send: No connected peers.")
            return 
        }
        
        // We must access NSManagedObject properties on the context thread or copy them
        // Here we assume the caller is on the correct context thread for the samples.
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
            print("Successfully sent \(dtos.count) samples to \(connectedPeers.count) peers.")
        } catch {
            print("Error encoding or sending samples: \(error.localizedDescription)")
        }
    }
}

// MARK: - MCSessionDelegate
extension SyncManager: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.connectedPeers = session.connectedPeers
            self.isConnected = !session.connectedPeers.isEmpty
        }
        print("Peer \(peerID.displayName) changed state to: \(state.rawValue)")
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
                let context = CoreDataManager.shared.container.newBackgroundContext()
                context.perform {
                    for dto in samples {
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
                        print("Received and saved \(samples.count) samples locally.")
                    }
                }
            }
        } catch {
            print("Failed to decode sync payload: \(error)")
        }
    }
    
    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension SyncManager: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("Accepting connection from \(peerID.displayName)")
        invitationHandler(true, self.session)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension SyncManager: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        print("Found peer \(peerID.displayName), inviting...")
        DispatchQueue.main.async {
            if !self.nearbyPeers.contains(peerID) {
                self.nearbyPeers.append(peerID)
            }
        }
        browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 30)
    }
    
    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("Lost peer \(peerID.displayName)")
        DispatchQueue.main.async {
            self.nearbyPeers.removeAll { $0 == peerID }
        }
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
