// WebSocketServer.swift — Serveur WebSocket léger basé sur Network.framework.
// Écoute sur le port 8765, accepte les connexions loopback, effectue le handshake
// RFC 6455, et décode les frames texte entrantes. Délègue la logique métier au
// PiPWindowController.

import Foundation
import Network
import CryptoKit

final class WebSocketServer {
    private let port: NWEndpoint.Port
    private let windowController: PiPWindowController
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "websocket.server")
    private var connections: [NWConnection] = []
    private let connectionsLock = NSLock()

    init(port: UInt16, windowController: PiPWindowController) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.windowController = windowController
    }

    // ─── Démarrage / arrêt ───────────────────────────────────────────────────
    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: port)
            listener.newConnectionHandler = { [weak self] conn in
                self?.handleNewConnection(conn)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    log("WebSocket listener prêt sur le port \(self.port.rawValue).")
                case .failed(let err):
                    log("WebSocket listener échec: \(err)")
                case .cancelled:
                    log("WebSocket listener annulé.")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            log("Impossible de créer le listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        let conns = currentConnections()
        for c in conns { c.cancel() }
    }

    // ─── Gestion des connexions ─────────────────────────────────────────────
    private func handleNewConnection(_ conn: NWConnection) {
        log("Nouvelle connexion TCP entrante.")
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.performHandshake(conn)
            case .failed(let err):
                log("Connexion échouée: \(err)")
                self?.removeConnection(conn)
            case .cancelled:
                self?.removeConnection(conn)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    // ─── Handshake WebSocket (RFC 6455) ─────────────────────────────────────
    private func performHandshake(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let error = error {
                log("Échec réception handshake: \(error)")
                conn.cancel()
                return
            }
            guard let data = data, let request = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            self.sendHandshakeResponse(conn, request: request)
        }
    }

    private func sendHandshakeResponse(_ conn: NWConnection, request: String) {
        guard let key = extractHeaderValue(request, key: "Sec-WebSocket-Key") else {
            log("Sec-WebSocket-Key manquant.")
            conn.cancel()
            return
        }
        let accept = sha1Base64(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """
        guard let bytes = response.data(using: .utf8) else { conn.cancel(); return }
        conn.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                log("Échec envoi handshake: \(error)")
                conn.cancel()
                return
            }
            log("Handshake WebSocket réussi.")
            self.addConnection(conn)
            self.startReceiving(conn)
        })
    }

    // ─── Réception des frames ───────────────────────────────────────────────
    private func startReceiving(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                log("Lecture client: \(error)")
                self.removeConnection(conn)
                return
            }
            if let data = data, !data.isEmpty {
                self.handleIncomingFrame(data: data, conn: conn)
            }
            if isComplete {
                log("Connexion fermée par le client.")
                self.removeConnection(conn)
                return
            }
            self.startReceiving(conn)
        }
    }

    private func handleIncomingFrame(data: Data, conn: NWConnection) {
        guard data.count >= 2 else { return }
        let fin = (data[0] & 0x80) != 0
        let opcode = data[0] & 0x0F
        let masked = (data[1] & 0x80) != 0
        var offset = 2
        var payloadLen = Int(data[1] & 0x7F)
        if payloadLen == 126 {
            guard data.count >= 4 else { return }
            payloadLen = (Int(data[2]) << 8) | Int(data[3])
            offset = 4
        } else if payloadLen == 127 {
            guard data.count >= 10 else { return }
            payloadLen = 0
            for i in 0..<8 {
                payloadLen = (payloadLen << 8) | Int(data[2 + i])
            }
            offset = 10
        }
        var maskKey: [UInt8] = []
        if masked {
            guard data.count >= offset + 4 else { return }
            maskKey = Array(data[offset..<offset + 4])
            offset += 4
        }
        guard data.count >= offset + payloadLen else { return }
        var payload = Array(data[offset..<offset + payloadLen])
        if masked {
            for i in 0..<payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }

        switch opcode {
        case 0x1: // Text frame
            if let text = String(bytes: payload, encoding: .utf8) {
                handleTextMessage(text, conn: conn)
            }
        case 0x8: // Close
            log("Client a demandé la fermeture.")
            removeConnection(conn)
            conn.cancel()
        case 0x9: // Ping -> Pong
            sendFrame(opcode: 0xA, payload: payload, conn: conn)
        case 0xA: // Pong
            break
        default:
            break
        }
        _ = fin
    }

    // ─── Traitement des messages JSON ───────────────────────────────────────
    private func handleTextMessage(_ text: String, conn: NWConnection) {
        log("Message reçu: \(text)")
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            log("Message JSON invalide.")
            return
        }

        switch action {
        case "START":
            let videoId = json["videoId"] as? String ?? ""
            let timestamp = json["timestamp"] as? Double ?? 0
            log("START reçu: videoId=\(videoId), timestamp=\(timestamp)")
            DispatchQueue.main.async { [weak self] in
                self?.windowController.showPiPWindow(videoId: videoId, timestamp: timestamp)
            }
        case "STOP":
            log("STOP reçu.")
            DispatchQueue.main.async { [weak self] in
                self?.windowController.stopAndSync { timestamp in
                    if let t = timestamp {
                        self?.sendToAll(json: ["action": "SYNC_TIME", "timestamp": t])
                    } else {
                        // Aucune fenêtre PiP n'était ouverte : on notifie l'extension
                        // pour qu'elle n'attende pas de SYNC_TIME et ne déclenche pas
                        // de lecture intempestive.
                        self?.sendToAll(json: ["action": "NO_PIP"])
                    }
                }
            }
        default:
            log("Action inconnue: \(action)")
        }
    }

    // ─── Envoi de messages ──────────────────────────────────────────────────
    func sendToAll(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        let conns = currentConnections()
        if conns.isEmpty {
            log("Aucun client connecté — message ignoré: \(text)")
            return
        }
        guard let frame = makeTextFrame(payload: text) else { return }
        for c in conns {
            c.send(content: frame, completion: .contentProcessed { error in
                if let error = error {
                    log("Échec envoi client: \(error)")
                }
            })
        }
        log("Envoyé à \(conns.count) client(s): \(text)")
    }

    private func sendFrame(opcode: UInt8, payload: [UInt8], conn: NWConnection) {
        var frame: [UInt8] = [0x80 | opcode]
        frame.append(UInt8(payload.count))
        frame.append(contentsOf: payload)
        conn.send(content: Data(frame), completion: .contentProcessed { _ in })
    }

    // ─── Gestion de la liste des connexions ─────────────────────────────────
    private func addConnection(_ conn: NWConnection) {
        connectionsLock.lock(); defer { connectionsLock.unlock() }
        connections.append(conn)
        log("Client connecté. Total: \(connections.count)")
    }

    private func removeConnection(_ conn: NWConnection) {
        connectionsLock.lock(); defer { connectionsLock.unlock() }
        connections.removeAll { $0 === conn }
        log("Client déconnecté. Total: \(connections.count)")
    }

    private func currentConnections() -> [NWConnection] {
        connectionsLock.lock(); defer { connectionsLock.unlock() }
        return connections
    }

    // ─── Helpers ────────────────────────────────────────────────────────────
    private func extractHeaderValue(_ request: String, key: String) -> String? {
        for line in request.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == key.lowercased() {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func sha1Base64(_ input: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(input.utf8))
        return Data(digest).base64EncodedString()
    }

    private func makeTextFrame(payload: String) -> Data? {
        let bytes = Array(payload.utf8)
        var frame: [UInt8] = [0x81] // FIN + text frame
        let len = bytes.count
        if len <= 125 {
            frame.append(UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((len >> UInt64(i * 8)) & 0xFF))
            }
        }
        frame.append(contentsOf: bytes)
        return Data(frame)
    }
}
