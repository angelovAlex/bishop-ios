//
//  StreamClient.swift
//  Server-sent events, deliverable as they arrive.
//
//  This cannot be `URLSession.dataTask(with:completionHandler:)`: that closure
//  runs once, when the whole response is finished, and an SSE response never
//  finishes - so the first version of this app showed the transcript and then
//  sat perfectly still while Bishop was writing. A data DELEGATE is fed every
//  chunk as it lands, which is what a live token stream needs.
//
//  Everything happens on the main queue (delegateQueue), so the callbacks can
//  touch the UI directly.
//

import Foundation

final class StreamClient: NSObject, URLSessionDataDelegate {
    /// Every parsed SSE object, decoded and in order.
    var onJSON: (([String: Any]) -> Void)?
    var onEnded: (() -> Void)?          // connection dropped: iOS does not reconnect for us

    private var task: URLSessionDataTask?
    private var buf = Data()
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func open(_ url: URL) {
        close()
        var r = URLRequest(url: url)
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 3600        // the server pings every 20 s while idle
        task = session.dataTask(with: r)
        task?.resume()
    }

    func close() {
        task?.cancel()
        task = nil
        buf.removeAll()
    }

    /// The Mac's EventSource is plain "data: {...}\n\n" (no event: names), and
    /// it may split a record across TCP chunks, so keep the tail in `buf`.
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buf.append(data)
        while let sep = buf.range(of: Data("\n\n".utf8)) {
            let record = buf.subdata(in: buf.startIndex..<sep.lowerBound)
            buf.removeSubrange(buf.startIndex..<sep.upperBound)
            guard let text = String(data: record, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.hasPrefix("data: ") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any] else { continue }
                onJSON?(obj)
            }
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A cancelled task is us closing it on purpose (or opening a new one).
        if error != nil, self.task === task { onEnded?() }
    }
}
