//
//  Bonjour.swift
//  Find the Mac on the LAN instead of asking Alex for an IP: browse for the
//  HTTP service webui.py advertises over mDNS, then remember the resolved
//  address. A phone that rejoins the Wi-Fi keeps working even if the router
//  hands the Mac a new lease.
//

import Foundation

final class Bonjour: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    /// Resolved "host:port" candidates, best first.
    private(set) var found: [String] = []

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_http._tcp.", inDomain: "local.")
    }

    /// A page served by webui.py says "Bishop" in its title; anything else on
    /// the network (routers, printers) is not the Mac.
    func probe(_ service: NetService, then done: @escaping (Bool) -> Void) {
        guard let host = hostName(service) else { return done(false) }
        let port = service.port
        guard let url = URL(string: "http://\(host):\(port)/") else { return done(false) }
        var r = URLRequest(url: url)
        r.timeoutInterval = 3
        URLSession.shared.dataTask(with: r) { data, _, _ in
            let html = data.flatMap { String(data: $0.prefix(2048), encoding: .utf8) } ?? ""
            let isBishop = html.contains("<title>Bishop</title>")
            if isBishop { self.remember("\(host):\(port)") }
            done(isBishop)
        }.resume()
    }

    private func hostName(_ service: NetService) -> String? {
        // NetService resolves to a name with a trailing dot; URL() wants it gone.
        var host = service.hostName
        if host?.hasSuffix(".") == true { host?.removeLast() }
        return host
    }

    private func remember(_ address: String) {
        DispatchQueue.main.async {
            if !self.found.contains(address) { self.found.insert(address, at: 0) }
        }
    }

    // MARK: NetServiceBrowserDelegate

    func netServiceBrowser(_ b: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 4)
    }

    func netServiceBrowser(_ b: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        guard hostName(service) != nil, service.port > 0 else { return }
        probe(service) { _ in }        // probe() decides what is the Mac
    }

    func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        services.removeAll { $0 == service }
    }
}
