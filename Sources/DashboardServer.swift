import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]   // 键为小写
    let body: Data

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

struct HTTPResponse {
    var status = 200
    var contentType = "application/json; charset=utf-8"
    var body = Data()

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }
    static func text(_ text: String, type: String = "text/plain; charset=utf-8", status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: type, body: Data(text.utf8))
    }
    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }
}

/// 只监听 127.0.0.1 的极简 HTTP 服务，给本机浏览器里的控制台（dashboard）用。
/// 安全：只绑定回环地址；校验 Host（防 DNS 重绑定）；
/// 改状态的请求（POST）必须带自定义请求头，别的网站的页面发不出来（防 CSRF）。
final class DashboardServer {
    static let preferredPort: UInt16 = 17890

    /// 在主线程调用
    var handler: ((HTTPRequest) -> HTTPResponse)?
    private(set) var port: UInt16 = 0
    var url: URL? { port == 0 ? nil : URL(string: "http://localhost:\(port)/") }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "LiveCaption.dashboard")

    func start() {
        // 首选端口被占用时依次往后试几个
        for candidate in Self.preferredPort..<(Self.preferredPort + 10) {
            guard let nwPort = NWEndpoint.Port(rawValue: candidate) else { continue }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            guard let listener = try? NWListener(using: params) else { continue }

            let ready = DispatchSemaphore(value: 0)
            var ok = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ok = true; ready.signal()
                case .failed, .cancelled: ready.signal()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 2)
            if ok {
                listener.stateUpdateHandler = nil
                self.listener = listener
                port = candidate
                Log.write("控制台：http://localhost:\(candidate)/")
                return
            }
            listener.cancel()
        }
        Log.write("控制台：启动失败（端口 \(Self.preferredPort) 起的 10 个都不可用）")
    }

    // MARK: - 连接处理（都在 queue 上）

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 1_000_000 { connection.cancel(); return }

            switch Self.parse(buffer) {
            case .request(let request):
                self.respond(to: request, on: connection)
            case .incomplete:
                if isComplete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }
            case .invalid:
                self.send(.error(400, "bad request"), on: connection)
            }
        }
    }

    private enum Parsed { case request(HTTPRequest), incomplete, invalid }

    private static func parse(_ data: Data) -> Parsed {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0 else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }

        let target = String(parts[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .request(HTTPRequest(method: String(parts[0]).uppercased(),
                                    path: components?.path ?? target,
                                    query: query, headers: headers,
                                    body: Data(data[bodyStart..<(bodyStart + length)])))
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        // Host 必须是本机回环地址：挡住 DNS 重绑定
        let host = request.headers["host"] ?? ""
        guard ["localhost:\(port)", "127.0.0.1:\(port)"].contains(host) else {
            send(.error(403, "forbidden host"), on: connection)
            return
        }
        // 改状态的请求必须带自定义头：别的网站的页面带不上（会触发被拒绝的跨域预检）
        if request.method != "GET" {
            guard request.method == "POST", request.headers["x-livecaption"] == "1" else {
                send(.error(403, "forbidden"), on: connection)
                return
            }
        }
        DispatchQueue.main.async { [weak self] in
            let response = self?.handler?(request) ?? .error(404, "not found")
            self?.queue.async { self?.send(response, on: connection) }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 409: "Conflict"][response.status] ?? "Error"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
