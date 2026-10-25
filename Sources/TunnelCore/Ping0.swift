import Foundation

/// Builds a fixed-host browser destination without requesting or parsing Ping0 content.
public enum Ping0Website {
    public static let homeURL = URL(string: "https://ping0.cc/")!

    public static func url(for ip: String?) -> URL {
        guard let address = publicIP(ip), let encoded = RiskIPAddress.encodedPath(address),
              let url = URL(string: "https://ping0.cc/ip/" + encoded) else { return homeURL }
        return url
    }

    public static func publicIP(_ raw: String?) -> String? {
        guard let raw, let ip = RiskIPAddress.canonical(raw) else { return nil }
        if ip.contains(":") {
            // Only ordinary global unicast addresses; special-use and translated addresses
            // fall back to the homepage instead of exposing a potentially private address.
            guard globalIPv6.contains(ip), !excludedIPv6.contains(where: { $0.contains(ip) }) else { return nil }
        } else if excludedIPv4.contains(where: { $0.contains(ip) }) { return nil }
        return ip
    }

    private static let globalIPv6 = RiskIPCIDR("2000::/3")!
    private static let excludedIPv6 = ["2001::/23", "2001:db8::/32", "2002::/16", "3fff::/20"]
        .compactMap(RiskIPCIDR.init)
    private static let excludedIPv4 = [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16",
        "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4"
    ].compactMap(RiskIPCIDR.init)
}
