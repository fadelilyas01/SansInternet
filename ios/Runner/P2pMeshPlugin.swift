import CoreBluetooth
import Flutter
import MultipeerConnectivity
import UIKit

/// Pont radio natif iOS compatible avec toutes les versions d'iOS (iOS 12.0 à iOS 18+) et toutes les versions d'Android :
/// 1. Apple `MultipeerConnectivity` (Wi-Fi Direct / AWDL + Bluetooth) pour les liaisons iOS <-> iOS.
/// 2. `CoreBluetooth` L2CAP Connection-Oriented Channels (`CBL2CAPChannel`) lorsque le pair Android est sous Android 10+ (API 29+).
/// 3. `CoreBluetooth` GATT Packet Characteristic (`0000FD9C-...` WriteWithoutResponse + Notify) avec segmentation/réassemblage
///    automatique lorsque le pair Android est sous Android 5.0 à 9.0 (API 21..28) ou que L2CAP est indisponible.
public final class P2pMeshPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var eventSink: FlutterEventSink?
    private var localPeerId: String = ""
    private var serviceCBUUID = CBUUID(string: "0000FD9A-0000-1000-8000-00805F9B34FB")
    private let psmCharacteristicUUID = CBUUID(string: "0000FD9B-0000-1000-8000-00805F9B34FB")
    private let gattPacketCharacteristicUUID = CBUUID(string: "0000FD9C-0000-1000-8000-00805F9B34FB")

    // MultipeerConnectivity (AWDL / Wi-Fi Direct iOS <-> iOS)
    private var mcpPeerID: MCPeerID?
    private var mcpSession: MCSession?
    private var mcpAdvertiser: MCNearbyServiceAdvertiser?
    private var mcpBrowser: MCNearbyServiceBrowser?
    private var connectedMcpPeers: [String: MCPeerID] = [:]

    // CoreBluetooth GATT + L2CAP CoC (Interopérabilité universelle iOS <-> Android toutes versions)
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var publishedL2capPSM: CBL2CAPPSM = 0
    private var gattPacketMutableChar: CBMutableCharacteristic?

    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var activeL2capChannels: [String: CBL2CAPChannel] = [:]
    private var activeGattPeripherals: [String: (CBPeripheral, CBCharacteristic)] = [:]
    private var subscribedCentrals: [String: CBCentral] = [:]

    private var streamBuffers: [String: Data] = [:]
    private var gattReassemblyBuffers: [String: (expectedLength: Int, buffer: Data)] = [:]

    public static func register(with registrar: FlutterPluginRegistrar) {
        let controlChannel = FlutterMethodChannel(
            name: "com.sansinternet.p2p/control",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "com.sansinternet.p2p/events",
            binaryMessenger: registrar.messenger()
        )
        let instance = P2pMeshPlugin()
        registrar.addMethodCallDelegate(instance, channel: controlChannel)
        eventChannel.setStreamHandler(instance)
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startMesh":
            guard let args = call.arguments as? [String: Any],
                  let peerId = args["localPeerId"] as? String,
                  let uuidStr = args["serviceUuid"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Paramètres startMesh manquants", details: nil))
                return
            }
            self.localPeerId = peerId
            self.serviceCBUUID = CBUUID(string: uuidStr)
            startMultipeerMesh()
            startCoreBluetoothUniversalStack()
            result(nil)

        case "stopMesh":
            stopAllRadios()
            result(nil)

        case "sendRawFrame":
            guard let args = call.arguments as? [String: Any],
                  let endpointId = args["endpointId"] as? String,
                  let typedData = args["bytes"] as? FlutterStandardTypedData else {
                result(FlutterError(code: "INVALID_ARGS", message: "Paramètres sendRawFrame manquants", details: nil))
                return
            }
            sendRawFrame(endpointId: endpointId, data: typedData.data, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startMultipeerMesh() {
        let shortName = String(localPeerId.prefix(16))
        let peerID = MCPeerID(displayName: shortName)
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self

        let advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["peerId": localPeerId],
            serviceType: "sansnet-mesh"
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()

        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: "sansnet-mesh")
        browser.delegate = self
        browser.startBrowsingForPeers()

        self.mcpPeerID = peerID
        self.mcpSession = session
        self.mcpAdvertiser = advertiser
        self.mcpBrowser = browser
    }

    private func startCoreBluetoothUniversalStack() {
        centralManager = CBCentralManager(
            delegate: self,
            queue: DispatchQueue.main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.sansinternet.ble.central"]
        )
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: DispatchQueue.main,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: "com.sansinternet.ble.peripheral"]
        )
    }

    private func sendRawFrame(endpointId: String, data: Data, result: @escaping FlutterResult) {
        if let peer = connectedMcpPeers[endpointId], let session = mcpSession {
            do {
                try session.send(data, toPeers: [peer], with: .reliable)
                result(nil)
            } catch {
                result(FlutterError(code: "MCP_SEND_FAILED", message: "Échec d'envoi Multipeer", details: nil))
            }
            return
        }

        if let channel = activeL2capChannels[endpointId], let outputStream = channel.outputStream {
            var lengthBigEndian = UInt16(data.count).bigEndian
            var framedData = Data(bytes: &lengthBigEndian, count: 2)
            framedData.append(data)

            let written = framedData.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return outputStream.write(baseAddress, maxLength: framedData.count)
            }
            if written == framedData.count {
                result(nil)
            } else {
                result(FlutterError(code: "L2CAP_WRITE_ERR", message: "Échec d'écriture sur le flux L2CAP", details: nil))
            }
            return
        }

        if endpointId.hasPrefix("gatt:") {
            let ok = sendSegmentedGattFrame(endpointId: endpointId, frame: data)
            if ok {
                result(nil)
            } else {
                result(FlutterError(code: "GATT_WRITE_ERR", message: "Échec d'envoi GATT universel", details: nil))
            }
            return
        }

        result(FlutterError(code: "PEER_NOT_CONNECTED", message: "Pair introuvable: \(endpointId)", details: nil))
    }

    private func sendSegmentedGattFrame(endpointId: String, frame: Data) -> Bool {
        let maxChunkPayload = 170
        var offset = 0
        var isFirst = true

        while offset < frame.count {
            var chunk = Data()
            if isFirst {
                let takeLen = min(frame.count - offset, maxChunkPayload - 3)
                chunk.append(0x01)
                chunk.append(UInt8((frame.count >> 8) & 0xFF))
                chunk.append(UInt8(frame.count & 0xFF))
                chunk.append(frame.subdata(in: offset..<(offset + takeLen)))
                offset += takeLen
                isFirst = false
            } else {
                let takeLen = min(frame.count - offset, maxChunkPayload - 1)
                chunk.append(0x00)
                chunk.append(frame.subdata(in: offset..<(offset + takeLen)))
                offset += takeLen
            }

            if let (peripheral, characteristic) = activeGattPeripherals[endpointId] {
                peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
            } else if let central = subscribedCentrals[endpointId],
                      let char = gattPacketMutableChar,
                      let periphMgr = peripheralManager {
                periphMgr.updateValue(chunk, for: char, onSubscribedCentrals: [central])
            } else {
                return false
            }
        }
        return true
    }

    private func processIncomingGattChunk(endpointId: String, chunk: Data) {
        guard !chunk.isEmpty else { return }
        let flag = chunk[chunk.startIndex]

        if flag == 0x01 {
            guard chunk.count >= 3 else { return }
            let totalLen = (Int(chunk[chunk.startIndex + 1]) << 8) | Int(chunk[chunk.startIndex + 2])
            guard totalLen > 0 && totalLen <= 4160 else { return }
            let body = chunk.subdata(in: (chunk.startIndex + 3)..<chunk.endIndex)
            if body.count >= totalLen {
                emitFrameReceived(endpointId: endpointId, data: body.prefix(totalLen))
            } else {
                gattReassemblyBuffers[endpointId] = (expectedLength: totalLen, buffer: body)
            }
        } else if flag == 0x00 {
            guard var state = gattReassemblyBuffers[endpointId] else { return }
            let body = chunk.subdata(in: (chunk.startIndex + 1)..<chunk.endIndex)
            state.buffer.append(body)
            if state.buffer.count >= state.expectedLength {
                gattReassemblyBuffers.removeValue(forKey: endpointId)
                emitFrameReceived(endpointId: endpointId, data: state.buffer.prefix(state.expectedLength))
            } else {
                gattReassemblyBuffers[endpointId] = state
            }
        }
    }

    private func emitFrameReceived(endpointId: String, data: Data) {
        emitEvent([
            "event": "frame_received",
            "endpointId": endpointId,
            "bytes": FlutterStandardTypedData(bytes: Data(data))
        ])
    }

    private func stopAllRadios() {
        mcpAdvertiser?.stopAdvertisingPeer()
        mcpBrowser?.stopBrowsingForPeers()
        mcpSession?.disconnect()
        connectedMcpPeers.removeAll()

        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        for (_, ch) in activeL2capChannels {
            ch.inputStream.close()
            ch.outputStream.close()
        }
        activeL2capChannels.removeAll()
        activeGattPeripherals.removeAll()
        subscribedCentrals.removeAll()
        discoveredPeripherals.removeAll()
        streamBuffers.removeAll()
        gattReassemblyBuffers.removeAll()
    }

    private func attachL2capChannel(_ channel: CBL2CAPChannel, advertisedPeerId: String, rssi: Int) {
        let endpointId = "ble:\(channel.peer.identifier.uuidString)"
        activeL2capChannels[endpointId] = channel
        streamBuffers[endpointId] = Data()

        channel.inputStream.delegate = self
        channel.outputStream.delegate = self
        channel.inputStream.schedule(in: .main, forMode: .default)
        channel.outputStream.schedule(in: .main, forMode: .default)
        channel.inputStream.open()
        channel.outputStream.open()

        emitEvent([
            "event": "peer_discovered",
            "endpointId": endpointId,
            "peerId": advertisedPeerId,
            "displayName": "Pair BLE (\(advertisedPeerId.prefix(8)))",
            "rssiDbm": rssi,
            "medium": "BLE L2CAP (iOS <-> Android)"
        ])
    }

    private func emitEvent(_ payload: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(payload)
        }
    }
}

// MARK: - MultipeerConnectivity (Haut débit iOS <-> iOS)
extension P2pMeshPlugin: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let endpointId = "mcp:\(peerID.displayName)"
        switch state {
        case .connected:
            connectedMcpPeers[endpointId] = peerID
            emitEvent([
                "event": "peer_discovered",
                "endpointId": endpointId,
                "peerId": peerID.displayName,
                "displayName": "Pair Multipeer (\(peerID.displayName.prefix(8)))",
                "rssiDbm": -48,
                "medium": "Apple Multipeer AWDL"
            ])
        case .notConnected:
            connectedMcpPeers.removeValue(forKey: endpointId)
            emitEvent([
                "event": "peer_disconnected",
                "endpointId": endpointId
            ])
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let endpointId = "mcp:\(peerID.displayName)"
        emitFrameReceived(endpointId: endpointId, data: data)
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, self.mcpSession)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let session = self.mcpSession else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let endpointId = "mcp:\(peerID.displayName)"
        connectedMcpPeers.removeValue(forKey: endpointId)
        emitEvent([
            "event": "peer_disconnected",
            "endpointId": endpointId
        ])
    }
}

// MARK: - CoreBluetooth Central, Peripheral, GATT Fallback (API 21+) & L2CAP (API 29+)
extension P2pMeshPlugin: CBCentralManagerDelegate, CBPeripheralDelegate, CBPeripheralManagerDelegate, StreamDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(
                withServices: [serviceCBUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {}

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let l2capId = "ble:\(peripheral.identifier.uuidString)"
        let gattId = "gatt:\(peripheral.identifier.uuidString)"
        if activeL2capChannels[l2capId] != nil ||
           activeGattPeripherals[gattId] != nil ||
           discoveredPeripherals[peripheral.identifier] != nil {
            return
        }
        discoveredPeripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceCBUUID])
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let gattId = "gatt:\(peripheral.identifier.uuidString)"
        discoveredPeripherals.removeValue(forKey: peripheral.identifier)
        if activeGattPeripherals.removeValue(forKey: gattId) != nil {
            gattReassemblyBuffers.removeValue(forKey: gattId)
            emitEvent(["event": "peer_disconnected", "endpointId": gattId])
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services where service.uuid == serviceCBUUID {
            peripheral.discoverCharacteristics([psmCharacteristicUUID, gattPacketCharacteristicUUID], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }
        for characteristic in characteristics where characteristic.uuid == psmCharacteristicUUID {
            peripheral.readValue(for: characteristic)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }

        if characteristic.uuid == psmCharacteristicUUID {
            guard data.count >= 18 else { return }
            let psmHigh = UInt16(data[data.startIndex]) << 8
            let psmLow = UInt16(data[data.startIndex + 1])
            let remotePsm = CBL2CAPPSM(psmHigh | psmLow)
            let peerData = data.subdata(in: (data.startIndex + 2)..<(data.startIndex + 18))
            let advertisedPeerId = String(data: peerData, encoding: .utf8) ?? peripheral.identifier.uuidString

            // Si le pair Android est sous Android 10+ (remotePsm > 0), on ouvre le canal L2CAP
            if remotePsm > 0 {
                peripheral.openL2CAPChannel(remotePsm)
                return
            }

            // Sinon (Android 5.0 à 9.0 où remotePsm == 0), on bascule sur la caractéristique GATT 0000FD9C-...
            if let service = characteristic.service,
               let packetChar = service.characteristics?.first(where: { $0.uuid == gattPacketCharacteristicUUID }) {
                let gattId = "gatt:\(peripheral.identifier.uuidString)"
                activeGattPeripherals[gattId] = (peripheral, packetChar)
                peripheral.setNotifyValue(true, for: packetChar)
                emitEvent([
                    "event": "peer_discovered",
                    "endpointId": gattId,
                    "peerId": advertisedPeerId,
                    "displayName": "Pair BLE (\(advertisedPeerId.prefix(8)))",
                    "rssiDbm": -62,
                    "medium": "BLE GATT Universel (Android 5+ <-> iOS)"
                ])
            }
            return
        }

        if characteristic.uuid == gattPacketCharacteristicUUID {
            let gattId = "gatt:\(peripheral.identifier.uuidString)"
            processIncomingGattChunk(endpointId: gattId, chunk: data)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel = channel, error == nil else { return }
        attachL2capChannel(channel, advertisedPeerId: peripheral.identifier.uuidString, rssi: -60)
    }

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            peripheral.publishL2CAPChannel(withEncryption: false)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {}

    public func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        self.publishedL2capPSM = (error == nil) ? PSM : 0

        var psmBigEndian = self.publishedL2capPSM.bigEndian
        var payload = Data(bytes: &psmBigEndian, count: 2)
        let peerPrefix = String(localPeerId.padding(toLength: 16, withPad: "0", startingAt: 0).prefix(16))
        if let peerBytes = peerPrefix.data(using: .utf8) {
            payload.append(peerBytes)
        }

        let psmCharacteristic = CBMutableCharacteristic(
            type: psmCharacteristicUUID,
            properties: [.read],
            value: payload,
            permissions: [.readable]
        )

        let packetCharacteristic = CBMutableCharacteristic(
            type: gattPacketCharacteristicUUID,
            properties: [.write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.writeable]
        )
        self.gattPacketMutableChar = packetCharacteristic

        let meshService = CBMutableService(type: serviceCBUUID, primary: true)
        meshService.characteristics = [psmCharacteristic, packetCharacteristic]
        peripheral.add(meshService)

        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceCBUUID],
            CBAdvertisementDataLocalNameKey: String(localPeerId.prefix(8))
        ])
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == gattPacketCharacteristicUUID else { return }
        let gattId = "gatt:\(central.identifier.uuidString)"
        subscribedCentrals[gattId] = central
        emitEvent([
            "event": "peer_discovered",
            "endpointId": gattId,
            "peerId": central.identifier.uuidString,
            "displayName": "Pair BLE GATT (\(central.identifier.uuidString.prefix(8)))",
            "rssiDbm": -60,
            "medium": "BLE GATT Universel (Android 5+ <-> iOS)"
        ])
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        let gattId = "gatt:\(central.identifier.uuidString)"
        subscribedCentrals.removeValue(forKey: gattId)
        gattReassemblyBuffers.removeValue(forKey: gattId)
        emitEvent(["event": "peer_disconnected", "endpointId": gattId])
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for req in requests {
            if req.characteristic.uuid == gattPacketCharacteristicUUID, let val = req.value {
                let gattId = "gatt:\(req.central.identifier.uuidString)"
                processIncomingGattChunk(endpointId: gattId, chunk: val)
            }
            peripheral.respond(to: req, withResult: .success)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel = channel, error == nil else { return }
        attachL2capChannel(channel, advertisedPeerId: channel.peer.identifier.uuidString, rssi: -58)
    }

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard let inputStream = aStream as? InputStream else { return }
        guard let endpointId = activeL2capChannels.first(where: { $0.value.inputStream === inputStream })?.key else {
            return
        }

        switch eventCode {
        case .hasBytesAvailable:
            var readBuf = [UInt8](repeating: 0, count: 1024)
            while inputStream.hasBytesAvailable {
                let count = inputStream.read(&readBuf, maxLength: readBuf.count)
                if count > 0 {
                    streamBuffers[endpointId, default: Data()].append(readBuf, count: count)
                } else {
                    break
                }
            }
            extractCompleteFrames(for: endpointId)

        case .endEncountered, .errorOccurred:
            if let ch = activeL2capChannels.removeValue(forKey: endpointId) {
                ch.inputStream.close()
                ch.outputStream.close()
            }
            streamBuffers.removeValue(forKey: endpointId)
            emitEvent([
                "event": "peer_disconnected",
                "endpointId": endpointId
            ])

        default:
            break
        }
    }

    private func extractCompleteFrames(for endpointId: String) {
        guard var buffer = streamBuffers[endpointId] else { return }
        while buffer.count >= 2 {
            let lenHigh = Int(buffer[buffer.startIndex]) << 8
            let lenLow = Int(buffer[buffer.startIndex + 1])
            let frameLen = lenHigh | lenLow

            if frameLen <= 0 || frameLen > 4160 {
                buffer.removeAll()
                break
            }
            if buffer.count < 2 + frameLen {
                break
            }
            let frameData = buffer.subdata(in: (buffer.startIndex + 2)..<(buffer.startIndex + 2 + frameLen))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 2 + frameLen))

            emitFrameReceived(endpointId: endpointId, data: frameData)
        }
        streamBuffers[endpointId] = buffer
    }
}
