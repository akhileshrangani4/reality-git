import Foundation

/// Serial owner calls offer/finish. A completion from a reset generation cannot release a newer slot.
public struct LatestObservationQueue: Sendable {
    public private(set) var inFlight: ObservationKey?
    public private(set) var pending: ObservationKey?
    public init() {}
    public mutating func offer(_ key: ObservationKey) -> ObservationKey? {
        if inFlight == nil { inFlight = key; return key }
        pending = key
        return nil
    }
    public mutating func finish(_ key: ObservationKey) -> ObservationKey? {
        guard inFlight == key else { return nil }
        inFlight = pending
        pending = nil
        return inFlight
    }
    public mutating func reset() { inFlight = nil; pending = nil }
}

public struct SourceFrameBuffer<Value> {
    private var entries: [(ObservationKey, Value)] = []
    public let capacity: Int
    public let lifetime: Double
    public init(capacity: Int = 12, lifetime: Double = 5) {
        self.capacity = max(1, capacity); self.lifetime = max(0, lifetime)
    }
    public var count: Int { entries.count }
    public mutating func prune(now: Double) {
        entries.removeAll { now - $0.0.captureTime > lifetime || now < $0.0.captureTime }
    }
    public mutating func insert(_ value: Value, for key: ObservationKey, now: Double) {
        prune(now: now)
        guard now >= key.captureTime, now - key.captureTime <= lifetime else { return }
        entries.removeAll { $0.0 == key }
        entries.append((key, value))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
    public mutating func value(for key: ObservationKey, now: Double) -> Value? {
        prune(now: now)
        return entries.first { $0.0 == key }?.1
    }
    public mutating func reset() { entries.removeAll() }
}

public enum AssistantPolicy {
    public static func validReply(_ reply: DetectionReply, sent: ObservationKey, now: Double,
                                  lastAcceptedTime: Double, sourceExists: Bool) -> Bool {
        guard reply.key == sent, sourceExists, now >= sent.captureTime,
              now - sent.captureTime <= 5, sent.captureTime > lastAcceptedTime,
              reply.confidence.isFinite, (0...1).contains(reply.confidence) else { return false }
        if let rect = reply.rect {
            guard rect.count == 4, rect.allSatisfy(\.isFinite), rect[0] >= 0, rect[1] >= 0,
                  rect[2] > 0, rect[3] > 0, rect[0] + rect[2] <= 1,
                  rect[1] + rect[3] <= 1 else { return false }
        }
        return true
    }
    public static func overlayIsFresh(age: Double, translation: Double, rotationRadians: Double) -> Bool {
        age >= 0 && age <= 0.25 && translation <= 0.015 && rotationRadians <= 0.025
            && translation >= 0 && rotationRadians >= 0
    }
    /// Development LAN endpoints only. Paths are rejected to avoid ambiguous route construction.
    public static func localEndpoint(_ address: String) -> URL? {
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "http", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let rawHost = parts.host?.lowercased(), !rawHost.isEmpty,
              parts.port == nil || (1...65535).contains(parts.port!) else { return nil }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = components.compactMap { Int($0) }
        let ipv4 = components.count == 4 && octets.count == 4 && octets.allSatisfy { (0...255).contains($0) }
            && (octets[0] == 10 || octets[0] == 127 || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 169 && octets[1] == 254))
        let localName = host == "localhost" || (host.hasSuffix(".local") && host.count > 6
            && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        // IPv6 is intentionally limited to loopback; use a .local name for other IPv6 Macs.
        guard ipv4 || localName || host == "::1" else { return nil }
        return parts.url
    }
}
