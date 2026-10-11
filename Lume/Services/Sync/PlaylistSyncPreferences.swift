extension Playlist {
    var syncFrequency: SyncFrequency {
        get { SyncFrequency.resolve(syncFrequencyRaw ?? "") }
        set { syncFrequencyRaw = newValue.rawValue }
    }
}
