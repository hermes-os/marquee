//
//  VolumeRegistry.swift
//  Marquee
//
//  Volume identity, resolution, and mount/unmount events.
//  See docs/ARCHITECTURE.md §"Catalog and library data flow" and
//  docs/ARCHITECTURE_DECISIONS.md ADR-002.
//
//  Resolves a filesystem URL to (volumeUUID, root-relative path), the
//  exact pair `MediaIdentity.mediaFileID` consumes. Subscribers can
//  observe mount/unmount transitions through `mountEvents()`.
//
//  Concrete implementations:
//    - `InMemoryVolumeRegistry`: deterministic, test-friendly. Pre-seed
//      volumes and call `simulateMount` / `simulateUnmount` from
//      harness scenarios.
//    - `SystemVolumeRegistry` (separate file): wraps NSWorkspace mount
//      notifications and `URLResourceKey.volumeUUIDStringKey`.
//

import Foundation

// MARK: - Value types

/// A snapshot of a currently-mounted volume.
///
/// `uuid` is canonical (lowercased + trimmed) so it matches
/// `MediaIdentity.normalizeVolumeUUID` without further work at the
/// call site. `mountPath` has any trailing slash stripped (root stays
/// `"/"`) so prefix matching against URL paths is unambiguous.
public struct VolumeDescriptor: Hashable, Codable, Sendable {
    public let uuid: String
    public let mountPath: String
    public let label: String?
    public let isRemovable: Bool
    public let isNetwork: Bool

    public init(
        uuid: String,
        mountPath: String,
        label: String? = nil,
        isRemovable: Bool = false,
        isNetwork: Bool = false
    ) {
        self.uuid = MediaIdentity.normalizeVolumeUUID(uuid)
        self.mountPath = Self.normalizeMountPath(mountPath)
        self.label = label
        self.isRemovable = isRemovable
        self.isNetwork = isNetwork
    }

    /// `/Volumes/FixtureDisk/` → `/Volumes/FixtureDisk`. Root stays `/`.
    /// Trailing slashes confuse prefix matching otherwise.
    static func normalizeMountPath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return "/" }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

public enum VolumeMountEvent: Sendable, Equatable {
    case mounted(VolumeDescriptor)
    case unmounted(uuid: String, mountPath: String)
}

public enum VolumeRegistryError: Error, Equatable {
    /// The given URL does not live under any currently-mounted volume.
    case pathNotOnMountedVolume(String)
}

// MARK: - Protocol

/// Resolves filesystem paths to (volume UUID, root-relative path) and
/// publishes mount/unmount events.
///
/// Conforming implementations are reference types so subscribers can
/// outlive a single call. Production code uses `SystemVolumeRegistry`;
/// tests and harnesses use `InMemoryVolumeRegistry`.
public protocol VolumeRegistry: AnyObject, Sendable {

    /// Resolve `url` to its containing volume and the path relative to
    /// that volume's mount point. The returned `relativePath` is in the
    /// canonical form expected by `MediaIdentity.mediaFileID` (forward
    /// slashes, no leading slash, no trailing slash).
    ///
    /// Throws `VolumeRegistryError.pathNotOnMountedVolume` if no
    /// currently-mounted volume covers the path.
    func resolve(url: URL) async throws
        -> (volume: VolumeDescriptor, relativePath: String)

    /// Snapshot of currently-mounted volumes. Order is not guaranteed.
    func mountedVolumes() async -> [VolumeDescriptor]

    /// Look up a currently-mounted volume by canonical UUID.
    func volume(byUUID uuid: String) async -> VolumeDescriptor?

    /// Stream of mount/unmount events. Each call returns a fresh stream
    /// — subscribers are independent. The stream finishes when the
    /// registry is deallocated or the iterator is dropped.
    func mountEvents() async -> AsyncStream<VolumeMountEvent>
}

// MARK: - Shared resolution helper

extension VolumeRegistry {

    /// Pure prefix-match used by every concrete implementation so the
    /// matching rule cannot drift between them.
    ///
    /// Picks the deepest matching mount path: a file at
    /// `/Volumes/FixtureDisk/Movies/x.mkv` resolves to `FixtureDisk`, not the
    /// root volume `/`. Comparison is case-sensitive (APFS preserves
    /// case; HFS+ does not, but we cannot inspect the volume's policy
    /// from a path string and gambling on case-folding has worse
    /// failure modes than missing a few rare HFS+-on-APFS cases).
    static func deepestMatch(
        path absolutePath: String,
        among volumes: [VolumeDescriptor]
    ) -> (volume: VolumeDescriptor, relativePath: String)? {
        let target = (absolutePath as NSString).standardizingPath
        var best: (VolumeDescriptor, String)?
        var bestLen = -1
        for v in volumes {
            let mount = v.mountPath
            let suffix: String?
            if mount == "/" {
                // Root matches everything; suffix is the whole path
                // sans leading slash.
                suffix = String(target.drop(while: { $0 == "/" }))
            } else if target == mount {
                suffix = ""
            } else if target.hasPrefix(mount + "/") {
                suffix = String(target.dropFirst(mount.count + 1))
            } else {
                suffix = nil
            }
            if let raw = suffix, mount.count > bestLen {
                best = (v, MediaIdentity.normalizeRelativePath(raw))
                bestLen = mount.count
            }
        }
        return best
    }
}

// MARK: - In-memory registry

/// Test/harness `VolumeRegistry`. Pre-seeded with fixture volumes;
/// `simulateMount` / `simulateUnmount` drive the event stream
/// deterministically. Not for production use.
public actor InMemoryVolumeRegistry: VolumeRegistry {

    private var volumes: [String: VolumeDescriptor] = [:]
    private var subscribers: [UUID: AsyncStream<VolumeMountEvent>.Continuation] = [:]

    public init(seed: [VolumeDescriptor] = []) {
        for v in seed { volumes[v.uuid] = v }
    }

    public func resolve(url: URL) async throws
        -> (volume: VolumeDescriptor, relativePath: String) {
        let path = url.standardized.path
        guard let match = Self.deepestMatch(
            path: path,
            among: Array(volumes.values)
        ) else {
            throw VolumeRegistryError.pathNotOnMountedVolume(path)
        }
        return match
    }

    public func mountedVolumes() async -> [VolumeDescriptor] {
        Array(volumes.values)
    }

    public func volume(byUUID uuid: String) async -> VolumeDescriptor? {
        volumes[MediaIdentity.normalizeVolumeUUID(uuid)]
    }

    public func mountEvents() async -> AsyncStream<VolumeMountEvent> {
        let token = UUID()
        // AsyncStream.init invokes its build closure synchronously to
        // produce the Continuation. We capture it via a class holder so
        // the pattern is sound under strict concurrency.
        let holder = ContinuationHolder<VolumeMountEvent>()
        let stream = AsyncStream<VolumeMountEvent> { c in
            holder.value = c
        }
        guard let continuation = holder.value else {
            // AsyncStream contract: the build closure runs once,
            // synchronously, before init returns.
            fatalError("AsyncStream did not invoke its build closure synchronously")
        }
        subscribers[token] = continuation
        // Capture self into an immutable local so the Task closure
        // (which is @Sendable) does not capture a mutable `weak self`
        // binding directly — that's rejected under strict concurrency.
        continuation.onTermination = { [weak self] _ in
            let captured = self
            Task { await captured?.removeSubscriber(token: token) }
        }
        return stream
    }

    // MARK: Test hooks

    /// Inserts (or replaces) a volume and broadcasts a `.mounted` event.
    /// Re-mounting an existing UUID still emits an event so tests can
    /// assert on it; production code should idempotency-check the
    /// snapshot rather than the event stream.
    public func simulateMount(_ descriptor: VolumeDescriptor) {
        volumes[descriptor.uuid] = descriptor
        broadcast(.mounted(descriptor))
    }

    /// Removes a volume and broadcasts a `.unmounted` event. No-op if
    /// the UUID was not mounted.
    public func simulateUnmount(uuid: String) {
        let canonical = MediaIdentity.normalizeVolumeUUID(uuid)
        guard let v = volumes.removeValue(forKey: canonical) else { return }
        broadcast(.unmounted(uuid: v.uuid, mountPath: v.mountPath))
    }

    // MARK: Internal

    private func removeSubscriber(token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    private func broadcast(_ event: VolumeMountEvent) {
        for c in subscribers.values { c.yield(event) }
    }
}

// MARK: - Continuation holder

/// Reference-typed box used to capture an `AsyncStream.Continuation`
/// out of `AsyncStream.init`'s build closure into the surrounding
/// actor-isolated context. The box itself is not shared across actor
/// boundaries — it is constructed, written, and read inside a single
/// isolated method — so `@unchecked Sendable` is sound here.
final class ContinuationHolder<T: Sendable>: @unchecked Sendable {
    var value: AsyncStream<T>.Continuation?
}
