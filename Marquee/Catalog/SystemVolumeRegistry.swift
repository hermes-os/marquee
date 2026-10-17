//
//  SystemVolumeRegistry.swift
//  Marquee
//
//  Production `VolumeRegistry` backed by
//  `URLResourceKey.volumeUUIDStringKey` and NSWorkspace mount
//  notifications. See `VolumeRegistry.swift` for the protocol.
//

import Foundation
import AppKit

/// macOS-native `VolumeRegistry`.
///
/// Resolution path: `URLResourceKey.volumeUUIDStringKey` is the
/// canonical identifier for local volumes. Network mounts (SMB/AFP)
/// frequently report no UUID; for those we synthesize a stable
/// identifier from `(mountPath, label)` tagged with a `net-` prefix so
/// network identifiers are visually distinguishable from real disk
/// UUIDs at a glance. The synthesis is documented next to the call so
/// future readers see the collision tradeoff: remounting a different
/// share at the same path with the same label collides — acceptable
/// for an offline-first home theater app where the user controls the
/// mount layout.
public actor SystemVolumeRegistry: VolumeRegistry {

    private var volumes: [String: VolumeDescriptor] = [:]
    private var subscribers: [UUID: AsyncStream<VolumeMountEvent>.Continuation] = [:]

    /// Observer tokens are retained for the lifetime of this actor, which
    /// is the lifetime of the app in production. Removal is intentionally
    /// not exposed — tests use `InMemoryVolumeRegistry` instead.
    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?

    public init() async {
        await refresh(emitDiff: false)
        installObservers()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        if let token = mountObserver { center.removeObserver(token) }
        if let token = unmountObserver { center.removeObserver(token) }
    }

    // MARK: - Protocol

    public func resolve(url: URL) async throws
        -> (volume: VolumeDescriptor, relativePath: String) {
        let target = url.standardized.path
        if let match = Self.deepestMatch(
            path: target,
            among: Array(volumes.values)
        ) {
            return match
        }
        // Stale cache fallback: a volume may have mounted between our
        // last refresh and this call (notification not yet delivered).
        // One refresh-and-retry is bounded and avoids an unnecessary
        // throw on a freshly-mounted volume.
        await refresh(emitDiff: true)
        guard let retry = Self.deepestMatch(
            path: target,
            among: Array(volumes.values)
        ) else {
            throw VolumeRegistryError.pathNotOnMountedVolume(target)
        }
        return retry
    }

    public func mountedVolumes() async -> [VolumeDescriptor] {
        Array(volumes.values)
    }

    public func volume(byUUID uuid: String) async -> VolumeDescriptor? {
        volumes[MediaIdentity.normalizeVolumeUUID(uuid)]
    }

    public func mountEvents() async -> AsyncStream<VolumeMountEvent> {
        let token = UUID()
        let holder = ContinuationHolder<VolumeMountEvent>()
        let stream = AsyncStream<VolumeMountEvent> { c in
            holder.value = c
        }
        guard let continuation = holder.value else {
            fatalError("AsyncStream did not invoke its build closure synchronously")
        }
        subscribers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            let captured = self
            Task { await captured?.removeSubscriber(token: token) }
        }
        return stream
    }

    // MARK: - Refresh + observers

    /// Re-walks the mounted volume list. When `emitDiff` is true, any
    /// volumes added or removed relative to the cached snapshot trigger
    /// `.mounted` / `.unmounted` events so subscribers see the
    /// transition even when we missed an NSWorkspace notification.
    private func refresh(emitDiff: Bool) async {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [
                .volumeUUIDStringKey,
                .volumeURLKey,
                .volumeNameKey,
                .volumeIsRemovableKey,
                .volumeIsLocalKey
            ],
            options: []
        ) ?? []

        var fresh: [String: VolumeDescriptor] = [:]
        for url in urls {
            if let desc = Self.descriptor(for: url) {
                fresh[desc.uuid] = desc
            }
        }

        // Narrow fallback: in the rare case where mountedVolumeURLs
        // returns an empty list (sandboxed processes, transient
        // CoreServices state during early launch), synthesize the root
        // volume directly so root-relative resolution still works.
        // Deliberately narrow — only the root, not a filesystem walk —
        // because anything broader would obscure real failures.
        if fresh.isEmpty,
           let rootDesc = Self.descriptor(for: URL(fileURLWithPath: "/")) {
            fresh[rootDesc.uuid] = rootDesc
        }

        if emitDiff {
            let oldUUIDs = Set(volumes.keys)
            let newUUIDs = Set(fresh.keys)
            for added in newUUIDs.subtracting(oldUUIDs) {
                if let v = fresh[added] { broadcast(.mounted(v)) }
            }
            for removed in oldUUIDs.subtracting(newUUIDs) {
                if let v = volumes[removed] {
                    broadcast(.unmounted(uuid: v.uuid, mountPath: v.mountPath))
                }
            }
        }
        volumes = fresh
    }

    private nonisolated func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        // NSWorkspace delivers mount/unmount notifications on the main
        // thread. We hop into the actor via Task to mutate state.
        let mountToken = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self,
                  let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            else { return }
            Task { await self.handleMount(url: url) }
        }
        let unmountToken = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self,
                  let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            else { return }
            Task { await self.handleUnmount(url: url) }
        }
        Task { await self.storeObservers(mount: mountToken, unmount: unmountToken) }
    }

    private func storeObservers(
        mount: NSObjectProtocol,
        unmount: NSObjectProtocol
    ) {
        self.mountObserver = mount
        self.unmountObserver = unmount
    }

    private func handleMount(url: URL) {
        guard let desc = Self.descriptor(for: url) else { return }
        if volumes[desc.uuid] == nil {
            volumes[desc.uuid] = desc
            broadcast(.mounted(desc))
        }
    }

    private func handleUnmount(url: URL) {
        let mountPath = VolumeDescriptor.normalizeMountPath(url.path)
        guard let key = volumes.first(where: { $0.value.mountPath == mountPath })?.key,
              let desc = volumes.removeValue(forKey: key) else {
            return
        }
        broadcast(.unmounted(uuid: desc.uuid, mountPath: desc.mountPath))
    }

    private func broadcast(_ event: VolumeMountEvent) {
        for c in subscribers.values { c.yield(event) }
    }

    private func removeSubscriber(token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    // MARK: - Descriptor build

    /// Build a `VolumeDescriptor` for `volumeURL`. Returns nil if the
    /// URL exposes neither a real UUID nor a synthesizable fallback
    /// (in practice: vanished mid-resolve, so the resource-values
    /// fetch itself fails).
    private static func descriptor(for volumeURL: URL) -> VolumeDescriptor? {
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey,
            .volumeURLKey,
            .volumeNameKey,
            .volumeIsRemovableKey,
            .volumeIsLocalKey
        ]
        guard let values = try? volumeURL.resourceValues(forKeys: keys) else {
            return nil
        }
        let mountURL = values.volume ?? volumeURL
        let mountPath = mountURL.path
        let label = values.volumeName
        let isRemovable = values.volumeIsRemovable ?? false
        let isLocal = values.volumeIsLocal ?? true
        let isNetwork = !isLocal

        if let uuid = values.volumeUUIDString, !uuid.isEmpty {
            return VolumeDescriptor(
                uuid: uuid,
                mountPath: mountPath,
                label: label,
                isRemovable: isRemovable,
                isNetwork: isNetwork
            )
        }
        // Network volumes commonly report no UUID. Synthesize a stable
        // identifier from `(mountPath, label)` so the same share at the
        // same mount yields the same UUID across launches. Tagged with
        // a `net-` prefix to distinguish from real disk UUIDs at a
        // glance. Collision risk: remounting a different share at the
        // identical path with the identical label collides — acceptable
        // for offline-first home theater use where the user controls
        // the mount layout.
        let payload = "v1|netvol|\(mountPath)|\(label ?? "")"
        let synth = "net-" + MediaIdentity.shortHash(payload)
        return VolumeDescriptor(
            uuid: synth,
            mountPath: mountPath,
            label: label,
            isRemovable: isRemovable,
            isNetwork: true
        )
    }
}
