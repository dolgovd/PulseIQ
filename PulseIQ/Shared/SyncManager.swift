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
    
    private override init() {
        super.init()
        
        #if os(macOS)
        let displayName = Host.current().localizedName ?? "Mac"
        #else
        let displayName = UIDevice.current.name
        #endif
        
        let peerId = MCPeerID(displayName: displayName)
        self.session = MCSession(peer: peerId, securityIdentity: nil, encryptionPreference: .required)
        self.session.delegate = self
        
        self.advertiser = MCNearbyServiceAdvertiser(peer: peerId, discoveryInfo: nil, serviceType: serviceType)
        self.advertiser.delegate = self
        
        self.browser = MCNearbyServiceBrowser(peer: peerId, serviceType: serviceType)
        self.browser.delegate = self
        
        self.advertiser.startAdvertisingPeer()
        self.browser.startBrowsingForPeers()
    }
    
    public func send(samples: [HealthSample]) {
        guard !session.connectedPeers.isEmpty else { return }
        
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
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            print("Sent \(dtos.count) samples over local network.")
        } catch {
            print("Failed to send samples: \(error)")
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
            let context = CoreDataManager.shared.container.newBackgroundContext()
            
            context.perform {
                for dto in payload.samples {
                    // Check if it already exists
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
                    print("Received and saved \(payload.samples.count) samples locally.")
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
        browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 30)
    }
    
    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("Lost peer \(peerID.displayName)")
    }
}

// MARK: - Sync Payload DTO
struct SyncPayload: Codable {
    struct SampleDto: Codable {
        let id: UUID
        let type: String
        let value: Double
        let startDate: Date
        let endDate: Date
    }
    let samples: [SampleDto]
}
