import Foundation

/// Engine appearance and the host's session task can arrive in either order.
/// Keep each host's transport separately and select it by the session owner;
/// an old host must never control a new host while its engine is mounting.
struct NowPlayingTransportRegistry {
    private struct Entry {
        let owner: ObjectIdentifier
        let transport: NowPlayingService.Transport
    }

    private var entries: [ActivityLease: Entry] = [:]

    func transport(for host: ActivityLease?) -> NowPlayingService.Transport? {
        guard let host else { return nil }
        return entries[host]?.transport
    }

    mutating func attach(_ transport: NowPlayingService.Transport, owner: AnyObject, host: ActivityLease) {
        entries[host] = Entry(owner: ObjectIdentifier(owner), transport: transport)
    }

    mutating func detach(owner: AnyObject, host: ActivityLease) {
        guard entries[host]?.owner == ObjectIdentifier(owner) else { return }
        entries[host] = nil
    }

    mutating func remove(host: ActivityLease) {
        entries[host] = nil
    }
}
