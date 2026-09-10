import Foundation
import Network

@MainActor
enum ThirdPartyModuleRuntime {
    static func syncServerWithDistribution() {
        if ThirdPartyModuleSourceStore.shared.distribution == .onDevice {
            startServer()
        } else {
            ThirdPartyModuleServer.shared.stop()
        }
    }

    static func prepareForImport() {
        startServer()
        guard ThirdPartyModuleSourceStore.shared.distribution == .onDevice else { return }
        BackgroundKeepAlive.shared.start()
    }

    static func endImportKeepAlive() {
        guard !ProxyManager.shared.isRunning else { return }
        BackgroundKeepAlive.shared.stop()
    }

    static func shutdown() {
        ThirdPartyModuleServer.shared.stop()
        endImportKeepAlive()
    }

    private static func startServer() {
        do {
            try ThirdPartyModuleServer.shared.start()
        } catch {
            RuntimeLogger.error("APP", "ThirdPartyModule", "本机模块服务启动失败", error: error)
        }
    }
}

@MainActor
final class ThirdPartyModuleServer: ObservableObject {
    static let shared = ThirdPartyModuleServer()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private var listener: NWListener?
    private var root: URL?

    func start(root: URL? = nil) throws {
        if isRunning, listener != nil { return }
        let resolved = try resolvedRoot(root)
        let nextListener = try makeListener()
        self.root = resolved
        listener = nextListener
        lastError = nil
        nextListener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handle(state)
            }
        }
        nextListener.newConnectionHandler = { [root = resolved] connection in
            ThirdPartyModuleConnection.handle(connection, root: root)
        }
        nextListener.start(queue: .global(qos: .userInitiated))
        isRunning = true
        RuntimeLogger.info("APP", "ThirdPartyModule", "本机模块服务已启动", details: [
            "地址": ThirdPartyModuleCatalog.localBaseURL.absoluteString
        ])
    }

    func stop() {
        listener?.cancel()
        listener = nil
        root = nil
        isRunning = false
        lastError = nil
    }

    private func resolvedRoot(_ root: URL?) throws -> URL {
        if let root { return root }
        guard let bundled = ThirdPartyModuleCatalog.bundledRoot() else {
            throw ThirdPartyModuleCatalogError.bundleMissing
        }
        return bundled
    }

    private func makeListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: ThirdPartyModuleCatalog.port)!
        )
        return try NWListener(
            using: parameters,
            on: NWEndpoint.Port(rawValue: ThirdPartyModuleCatalog.port)!
        )
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            lastError = nil
        case .failed(let error):
            lastError = error.localizedDescription
            isRunning = false
            listener = nil
            RuntimeLogger.error("APP", "ThirdPartyModule", "本机模块服务异常", error: error)
        case .cancelled:
            isRunning = false
            listener = nil
        default:
            break
        }
    }
}

enum ThirdPartyModuleConnection {
    static func handle(_ connection: NWConnection, root: URL) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection: connection, root: root, buffer: Data())
    }

    private static func receive(connection: NWConnection, root: URL, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, isComplete, error in
            if error != nil {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let request = String(data: next, encoding: .utf8), request.contains("\r\n\r\n") {
                let payload = ThirdPartyModuleHTTP.encode(
                    ThirdPartyModuleHTTP.response(for: request, root: root)
                )
                connection.send(content: payload, completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            if isComplete || next.count > 16_384 {
                connection.cancel()
                return
            }
            receive(connection: connection, root: root, buffer: next)
        }
    }
}
