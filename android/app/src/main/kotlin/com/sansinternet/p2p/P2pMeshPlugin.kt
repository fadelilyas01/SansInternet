package com.sansinternet.p2p

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.AdvertisingOptions
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionsStatusCodes
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo
import com.google.android.gms.nearby.connection.DiscoveryOptions
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import com.google.android.gms.nearby.connection.Strategy
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import kotlin.math.min

/**
 * Pont radio natif Android compatible avec TOUTES les versions d'Android (Android 5.0 API 21 à Android 15+ API 35) :
 *
 * 1. Android 10+ (API 29..35) : Ouverture de sockets BLE `L2CAP Connection-Oriented Channels` (`listenUsingInsecureL2capChannel`)
 *    + `LE Coded PHY` (Long Range Bluetooth 5.0 sur API 26+).
 * 2. Android 5.0 à 9.0 (API 21..28) & Fallback universel iOS 12+ : Transport par segmentation/réassemblage GATT
 *    sur la caractéristique universelle `0000FD9C-0000-1000-8000-00805F9B34FB` (WRITE_NO_RESPONSE + NOTIFY).
 * 3. Gestion rétrocompatible des appels `readCharacteristic` / `writeCharacteristic` dépréciés en API 33 (Tiramisu).
 */
class P2pMeshPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var applicationContext: Context
    private lateinit var controlChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newCachedThreadPool()

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    private var localPeerId: String = ""
    private var serviceUuid: UUID = UUID.fromString("0000FD9A-0000-1000-8000-00805F9B34FB")
    private val psmCharacteristicUuid: UUID = UUID.fromString("0000FD9B-0000-1000-8000-00805F9B34FB")
    private val gattPacketCharacteristicUuid: UUID = UUID.fromString("0000FD9C-0000-1000-8000-00805F9B34FB")
    private val cccdUuid: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    private var l2capServerSocket: BluetoothServerSocket? = null
    private var gattServer: BluetoothGattServer? = null
    private var gattPacketCharacteristic: BluetoothGattCharacteristic? = null

    private val activeL2capSockets = ConcurrentHashMap<String, BluetoothSocket>()
    private val activeGattClients = ConcurrentHashMap<String, BluetoothGatt>()
    private val subscribedGattDevices = ConcurrentHashMap<String, BluetoothDevice>()
    private val gattReassemblyBuffers = ConcurrentHashMap<String, ReassemblyState>()
    private val pendingGattConnections = ConcurrentHashMap<String, Boolean>()
    private val nearbyConnectedEndpoints = ConcurrentHashMap<String, String>()

    private class ReassemblyState(val expectedLength: Int) {
        val buffer = ByteArrayOutputStream(expectedLength)
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        controlChannel = MethodChannel(binding.binaryMessenger, "com.sansinternet.p2p/control")
        eventChannel = EventChannel(binding.binaryMessenger, "com.sansinternet.p2p/events")
        controlChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopAllRadios()
        controlChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        ioExecutor.shutdownNow()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startMesh" -> {
                val peerIdArg = call.argument<String>("localPeerId")
                val uuidArg = call.argument<String>("serviceUuid")
                if (peerIdArg.isNullOrBlank() || uuidArg.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "localPeerId et serviceUuid sont requis", null)
                    return
                }
                localPeerId = peerIdArg
                serviceUuid = UUID.fromString(uuidArg)
                startNearbyCluster()
                startUniversalBleStack()
                result.success(null)
            }
            "stopMesh" -> {
                stopAllRadios()
                result.success(null)
            }
            "sendRawFrame" -> {
                val endpointId = call.argument<String>("endpointId")
                val bytes = call.argument<ByteArray>("bytes")
                if (endpointId == null || bytes == null) {
                    result.error("INVALID_ARGS", "endpointId et bytes sont requis", null)
                    return
                }
                sendFrameToEndpoint(endpointId, bytes, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun startNearbyCluster() {
        val connectionsClient = Nearby.getConnectionsClient(applicationContext)
        val serviceId = "com.sansinternet.mesh.cluster"

        val advertisingOptions = AdvertisingOptions.Builder()
            .setStrategy(Strategy.P2P_CLUSTER)
            .build()

        val safeEndpointName = if (localPeerId.length > 32) localPeerId.substring(0, 32) else localPeerId

        connectionsClient.startAdvertising(
            safeEndpointName,
            serviceId,
            nearbyLifecycleCallback,
            advertisingOptions
        ).addOnFailureListener {
            // Tolérance si permissions ou Bluetooth en cours de démarrage
        }

        val discoveryOptions = DiscoveryOptions.Builder()
            .setStrategy(Strategy.P2P_CLUSTER)
            .build()

        connectionsClient.startDiscovery(
            serviceId,
            nearbyDiscoveryCallback,
            discoveryOptions
        ).addOnFailureListener {
            // Tolérance si permissions ou Bluetooth en cours de démarrage
        }
    }

    @SuppressLint("MissingPermission")
    private fun startUniversalBleStack() {
        val btManager = applicationContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter: BluetoothAdapter = btManager?.adapter ?: return
        if (!adapter.isEnabled) return

        // Sur Android 10+ (API 29+), on ouvre un serveur L2CAP CoC.
        // Sur Android 5.0..9.0 (API 21..28), dynamicPsm vaut 0 et la communication bascule automatiquement
        // sur la caractéristique de streaming GATT universelle (0000FD9C-...).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ioExecutor.execute {
                try {
                    val server = adapter.listenUsingInsecureL2capChannel()
                    l2capServerSocket = server
                    val dynamicPsm = server.psm

                    startUniversalGattServer(btManager, dynamicPsm)
                    startBleAdvertisingWithPsm(adapter, dynamicPsm)
                    startBleScanning(adapter)

                    while (!Thread.currentThread().isInterrupted) {
                        val socket = server.accept()
                        val remoteId = "ble:${socket.remoteDevice.address}"
                        activeL2capSockets[remoteId] = socket
                        handleL2capSocketLoop(remoteId, socket)
                    }
                } catch (_: Exception) {
                    // Fallback sur GATT pur si le contrôleur Bluetooth ne supporte pas L2CAP
                    startUniversalGattServer(btManager, 0)
                    startBleAdvertisingWithPsm(adapter, 0)
                    startBleScanning(adapter)
                }
            }
        } else {
            startUniversalGattServer(btManager, 0)
            startBleAdvertisingWithPsm(adapter, 0)
            startBleScanning(adapter)
        }
    }

    @SuppressLint("MissingPermission")
    private fun startUniversalGattServer(btManager: BluetoothManager, dynamicPsm: Int) {
        val server = btManager.openGattServer(applicationContext, object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
                val endpointId = "gatt:${device.address}"
                if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    subscribedGattDevices.remove(endpointId)
                    gattReassemblyBuffers.remove(endpointId)
                    emitEvent(mapOf("event" to "peer_disconnected", "endpointId" to endpointId))
                }
            }

            override fun onCharacteristicReadRequest(
                device: BluetoothDevice,
                requestId: Int,
                offset: Int,
                characteristic: BluetoothGattCharacteristic
            ) {
                if (characteristic.uuid == psmCharacteristicUuid) {
                    val peerBytes = localPeerId.toByteArray(Charsets.UTF_8)
                    val psmBuffer = ByteBuffer.allocate(2 + peerBytes.size)
                    psmBuffer.putShort(dynamicPsm.toShort())
                    psmBuffer.put(peerBytes)
                    val fullValue = psmBuffer.array()
                    val slice = if (offset < fullValue.size) fullValue.copyOfRange(offset, fullValue.size) else ByteArray(0)
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice)
                } else {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, 0, null)
                }
            }

            override fun onDescriptorWriteRequest(
                device: BluetoothDevice,
                requestId: Int,
                descriptor: BluetoothGattDescriptor,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray?
            ) {
                val endpointId = "gatt:${device.address}"
                subscribedGattDevices[endpointId] = device
                descriptor.value = value
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                }
                emitEvent(
                    mapOf(
                        "event" to "peer_discovered",
                        "endpointId" to endpointId,
                        "peerId" to device.address,
                        "displayName" to "Pair BLE (${device.address.takeLast(5)})",
                        "rssiDbm" to -62,
                        "medium" to "BLE GATT Universel (API 21+)",
                        "isInitiator" to false
                    )
                )
            }

            override fun onCharacteristicWriteRequest(
                device: BluetoothDevice,
                requestId: Int,
                characteristic: BluetoothGattCharacteristic,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray?
            ) {
                if (characteristic.uuid == gattPacketCharacteristicUuid && value != null) {
                    val endpointId = "gatt:${device.address}"
                    processIncomingGattChunk(endpointId, value)
                }
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                }
            }
        }) ?: return

        val psmChar = BluetoothGattCharacteristic(
            psmCharacteristicUuid,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ
        )

        val packetChar = BluetoothGattCharacteristic(
            gattPacketCharacteristicUuid,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        val cccd = BluetoothGattDescriptor(
            cccdUuid,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
        )
        packetChar.addDescriptor(cccd)
        gattPacketCharacteristic = packetChar

        val service = BluetoothGattService(serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(psmChar)
        service.addCharacteristic(packetChar)
        server.addService(service)
        gattServer = server
    }

    /**
     * Protocole de segmentation GATT universel (compatible MTU 23..512 octets sur Android 5+ et iOS 12+) :
     * - Premier fragment (`flag = 0x01`) : `[0x01, lenHigh, lenLow, ...payload]`
     * - Fragments suivants (`flag = 0x00`) : `[0x00, ...payload]`
     */
    private fun processIncomingGattChunk(endpointId: String, chunk: ByteArray) {
        if (chunk.isEmpty()) return
        val flag = chunk[0].toInt() and 0xFF
        if (flag == 0x01) {
            if (chunk.size < 3) return
            val totalLen = ((chunk[1].toInt() and 0xFF) shl 8) or (chunk[2].toInt() and 0xFF)
            if (totalLen <= 0 || totalLen > 4160) return
            val state = ReassemblyState(totalLen)
            state.buffer.write(chunk, 3, chunk.size - 3)
            if (state.buffer.size() >= totalLen) {
                emitCompleteGattFrame(endpointId, state.buffer.toByteArray().copyOf(totalLen))
            } else {
                gattReassemblyBuffers[endpointId] = state
            }
        } else if (flag == 0x00) {
            val state = gattReassemblyBuffers[endpointId] ?: return
            state.buffer.write(chunk, 1, chunk.size - 1)
            if (state.buffer.size() >= state.expectedLength) {
                gattReassemblyBuffers.remove(endpointId)
                emitCompleteGattFrame(endpointId, state.buffer.toByteArray().copyOf(state.expectedLength))
            }
        }
    }

    private fun emitCompleteGattFrame(endpointId: String, frameBytes: ByteArray) {
        emitEvent(
            mapOf(
                "event" to "frame_received",
                "endpointId" to endpointId,
                "bytes" to frameBytes
            )
        )
    }

    @SuppressLint("MissingPermission")
    private fun startBleAdvertisingWithPsm(adapter: BluetoothAdapter, psm: Int) {
        val advertiser = adapter.bluetoothLeAdvertiser ?: return

        val peerBytes = localPeerId.toByteArray(Charsets.UTF_8)
        val serviceDataBuffer = ByteBuffer.allocate(2 + peerBytes.size)
        serviceDataBuffer.putShort(psm.toShort())
        serviceDataBuffer.put(peerBytes)

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(serviceUuid))
            .build()

        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceData(ParcelUuid(serviceUuid), serviceDataBuffer.array())
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            adapter.isLeExtendedAdvertisingSupported &&
            adapter.isLeCodedPhySupported
        ) {
            val params = AdvertisingSetParameters.Builder()
                .setLegacyMode(false)
                .setConnectable(true)
                .setInterval(AdvertisingSetParameters.INTERVAL_LOW)
                .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_HIGH)
                .setPrimaryPhy(BluetoothDevice.PHY_LE_1M)
                .setSecondaryPhy(BluetoothDevice.PHY_LE_CODED)
                .build()
            advertiser.startAdvertisingSet(params, data, scanResponse, null, null, bleExtendedAdvertiseCallback)
            return
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()

        advertiser.startAdvertising(settings, data, scanResponse, bleAdvertiseCallback)
    }

    @SuppressLint("MissingPermission")
    private fun startBleScanning(adapter: BluetoothAdapter) {
        val scanner = adapter.bluetoothLeScanner ?: return
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(serviceUuid))
            .build()
        val settingsBuilder = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && adapter.isLeCodedPhySupported) {
            settingsBuilder
                .setLegacy(false)
                .setPhy(ScanSettings.PHY_LE_ALL_SUPPORTED)
        }

        scanner.startScan(listOf(filter), settingsBuilder.build(), bleScanCallback)
    }

    private fun handleL2capSocketLoop(endpointId: String, socket: BluetoothSocket) {
        ioExecutor.execute {
            try {
                val input: InputStream = socket.inputStream
                val lenBuf = ByteArray(2)
                while (socket.isConnected && !Thread.currentThread().isInterrupted) {
                    val readHeader = input.read(lenBuf)
                    if (readHeader < 2) break
                    val frameLen = ((lenBuf[0].toInt() and 0xFF) shl 8) or (lenBuf[1].toInt() and 0xFF)
                    if (frameLen <= 0 || frameLen > 4160) break

                    val frameBytes = ByteArray(frameLen)
                    var offset = 0
                    while (offset < frameLen) {
                        val r = input.read(frameBytes, offset, frameLen - offset)
                        if (r <= 0) break
                        offset += r
                    }
                    if (offset == frameLen) {
                        emitEvent(
                            mapOf(
                                "event" to "frame_received",
                                "endpointId" to endpointId,
                                "bytes" to frameBytes
                            )
                        )
                    }
                }
            } catch (_: Exception) {
                // Déconnexion du pair BLE
            } finally {
                activeL2capSockets.remove(endpointId)
                try {
                    socket.close()
                } catch (_: Exception) {}
                emitEvent(
                    mapOf(
                        "event" to "peer_disconnected",
                        "endpointId" to endpointId
                    )
                )
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun sendFrameToEndpoint(
        endpointId: String,
        bytes: ByteArray,
        result: MethodChannel.Result
    ) {
        if (endpointId.startsWith("ble:")) {
            val socket = activeL2capSockets[endpointId]
            if (socket == null || !socket.isConnected) {
                result.error("LINK_DOWN", "Canal BLE L2CAP fermé pour $endpointId", null)
                return
            }
            ioExecutor.execute {
                try {
                    val out: OutputStream = socket.outputStream
                    val header = byteArrayOf(
                        ((bytes.size shr 8) and 0xFF).toByte(),
                        (bytes.size and 0xFF).toByte()
                    )
                    synchronized(out) {
                        out.write(header)
                        out.write(bytes)
                        out.flush()
                    }
                    mainHandler.post { result.success(null) }
                } catch (_: Exception) {
                    mainHandler.post {
                        result.error("IO_ERR", "Échec d'écriture sur le canal L2CAP", null)
                    }
                }
            }
            return
        }

        if (endpointId.startsWith("gatt:")) {
            ioExecutor.execute {
                val ok = sendSegmentedGattFrame(endpointId, bytes)
                mainHandler.post {
                    if (ok) {
                        result.success(null)
                    } else {
                        result.error("GATT_ERR", "Échec d'envoi GATT vers $endpointId", null)
                    }
                }
            }
            return
        }

        val payload = Payload.fromBytes(bytes)
        Nearby.getConnectionsClient(applicationContext)
            .sendPayload(endpointId, payload)
            .addOnSuccessListener { result.success(null) }
            .addOnFailureListener {
                result.error("NEARBY_SEND_FAILED", "Échec de transmission Nearby", null)
            }
    }

    @SuppressLint("MissingPermission", "deprecation")
    private fun sendSegmentedGattFrame(endpointId: String, frame: ByteArray): Boolean {
        val maxChunkPayload = 170 // Compatible avec MTU négocié standard (185 octets sur iOS/Android)
        var offset = 0
        var isFirst = true

        val gattClient = activeGattClients[endpointId]
        val subscribedDevice = subscribedGattDevices[endpointId]
        val localPacketChar = gattPacketCharacteristic

        while (offset < frame.size) {
            val chunk: ByteArray
            if (isFirst) {
                val takeLen = min(frame.size - offset, maxChunkPayload - 3)
                chunk = ByteArray(3 + takeLen)
                chunk[0] = 0x01
                chunk[1] = ((frame.size shr 8) and 0xFF).toByte()
                chunk[2] = (frame.size and 0xFF).toByte()
                System.arraycopy(frame, offset, chunk, 3, takeLen)
                offset += takeLen
                isFirst = false
            } else {
                val takeLen = min(frame.size - offset, maxChunkPayload - 1)
                chunk = ByteArray(1 + takeLen)
                chunk[0] = 0x00
                System.arraycopy(frame, offset, chunk, 1, takeLen)
                offset += takeLen
            }

            if (gattClient != null) {
                val remoteChar = gattClient.getService(serviceUuid)?.getCharacteristic(gattPacketCharacteristicUuid)
                    ?: return false
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gattClient.writeCharacteristic(
                        remoteChar,
                        chunk,
                        BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                    )
                } else {
                    remoteChar.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                    remoteChar.value = chunk
                    gattClient.writeCharacteristic(remoteChar)
                }
            } else if (subscribedDevice != null && localPacketChar != null && gattServer != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gattServer?.notifyCharacteristicChanged(subscribedDevice, localPacketChar, false, chunk)
                } else {
                    localPacketChar.value = chunk
                    gattServer?.notifyCharacteristicChanged(subscribedDevice, localPacketChar, false)
                }
            } else {
                return false
            }

            try {
                Thread.sleep(12)
            } catch (_: InterruptedException) {
                return false
            }
        }
        return true
    }

    @SuppressLint("MissingPermission")
    private fun stopAllRadios() {
        val connectionsClient = Nearby.getConnectionsClient(applicationContext)
        connectionsClient.stopAdvertising()
        connectionsClient.stopDiscovery()
        connectionsClient.stopAllEndpoints()
        nearbyConnectedEndpoints.clear()

        try {
            gattServer?.close()
        } catch (_: Exception) {}
        gattServer = null
        pendingGattConnections.clear()
        subscribedGattDevices.clear()
        gattReassemblyBuffers.clear()

        for ((_, gatt) in activeGattClients) {
            try {
                gatt.close()
            } catch (_: Exception) {}
        }
        activeGattClients.clear()

        try {
            l2capServerSocket?.close()
        } catch (_: Exception) {}
        l2capServerSocket = null

        for ((_, sock) in activeL2capSockets) {
            try {
                sock.close()
            } catch (_: Exception) {}
        }
        activeL2capSockets.clear()
    }

    private fun emitEvent(payload: Map<String, Any>) {
        mainHandler.post {
            eventSink?.success(payload)
        }
    }

    private val nearbyDiscoveryCallback = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
            Nearby.getConnectionsClient(applicationContext)
                .requestConnection(localPeerId, endpointId, nearbyLifecycleCallback)
        }

        override fun onEndpointLost(endpointId: String) {
            nearbyConnectedEndpoints.remove(endpointId)
            emitEvent(
                mapOf(
                    "event" to "peer_disconnected",
                    "endpointId" to endpointId
                )
            )
        }
    }

    private val nearbyLifecycleCallback = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, connectionInfo: ConnectionInfo) {
            nearbyConnectedEndpoints[endpointId] = connectionInfo.endpointName
            Nearby.getConnectionsClient(applicationContext)
                .acceptConnection(endpointId, nearbyPayloadCallback)
        }

        override fun onConnectionResult(endpointId: String, resolution: ConnectionResolution) {
            if (resolution.status.statusCode == ConnectionsStatusCodes.STATUS_OK) {
                val peerId = nearbyConnectedEndpoints[endpointId] ?: endpointId
                emitEvent(
                    mapOf(
                        "event" to "peer_discovered",
                        "endpointId" to endpointId,
                        "peerId" to peerId,
                        "displayName" to "Pair Nearby (${peerId.take(8)})",
                        "rssiDbm" to -52,
                        "medium" to "Nearby P2P_CLUSTER"
                    )
                )
            } else {
                nearbyConnectedEndpoints.remove(endpointId)
            }
        }

        override fun onDisconnected(endpointId: String) {
            nearbyConnectedEndpoints.remove(endpointId)
            emitEvent(
                mapOf(
                    "event" to "peer_disconnected",
                    "endpointId" to endpointId
                )
            )
        }
    }

    private val nearbyPayloadCallback = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) {
            if (payload.type == Payload.Type.BYTES) {
                val bytes = payload.asBytes() ?: return
                emitEvent(
                    mapOf(
                        "event" to "frame_received",
                        "endpointId" to endpointId,
                        "bytes" to bytes
                    )
                )
            }
        }

        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {}
    }

    private val bleAdvertiseCallback = object : AdvertiseCallback() {}

    private val bleExtendedAdvertiseCallback = object : AdvertisingSetCallback() {
        override fun onAdvertisingSetStarted(
            advertisingSet: AdvertisingSet?,
            txPower: Int,
            status: Int
        ) {}
    }

    private val bleScanCallback = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device: BluetoothDevice = result.device
            val l2capEndpointId = "ble:${device.address}"
            val gattEndpointId = "gatt:${device.address}"
            if (activeL2capSockets.containsKey(l2capEndpointId) ||
                activeGattClients.containsKey(gattEndpointId) ||
                subscribedGattDevices.containsKey(gattEndpointId)
            ) {
                return
            }

            val scanRecord = result.scanRecord
            val serviceData = scanRecord?.getServiceData(ParcelUuid(serviceUuid))

            // Cas 1 : Android 10+ -> Android 10+ avec PSM annoncé directement dans ServiceData
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && serviceData != null && serviceData.size >= 2) {
                val buf = ByteBuffer.wrap(serviceData)
                val psm = buf.short.toInt() and 0xFFFF
                val peerBytes = ByteArray(buf.remaining())
                buf.get(peerBytes)
                val advertisedPeerId = if (peerBytes.isNotEmpty()) String(peerBytes, Charsets.UTF_8) else device.address
                if (psm > 0) {
                    connectL2capSocket(device, l2capEndpointId, psm, advertisedPeerId, result.rssi)
                    return
                }
            }

            // Cas 2 : Connexion GATT universelle (iOS ou Android 5.0..9.0 sans L2CAP)
            if (pendingGattConnections.putIfAbsent(gattEndpointId, true) != null) return

            device.connectGatt(applicationContext, false, object : BluetoothGattCallback() {
                override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                    if (newState == BluetoothProfile.STATE_CONNECTED) {
                        gatt.requestMtu(247)
                    } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                        pendingGattConnections.remove(gattEndpointId)
                        activeGattClients.remove(gattEndpointId)
                        gattReassemblyBuffers.remove(gattEndpointId)
                        gatt.close()
                        emitEvent(mapOf("event" to "peer_disconnected", "endpointId" to gattEndpointId))
                    }
                }

                override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                    gatt.discoverServices()
                }

                override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                    val service = gatt.getService(serviceUuid)
                    val psmChar = service?.getCharacteristic(psmCharacteristicUuid)
                    if (psmChar != null) {
                        gatt.readCharacteristic(psmChar)
                    } else {
                        pendingGattConnections.remove(gattEndpointId)
                        gatt.disconnect()
                    }
                }

                // Compatible Android 13+ (API 33+)
                override fun onCharacteristicRead(
                    gatt: BluetoothGatt,
                    characteristic: BluetoothGattCharacteristic,
                    value: ByteArray,
                    status: Int
                ) {
                    handlePsmCharacteristicRead(gatt, device, value, status, result.rssi)
                }

                // Compatible Android 5.0 à 12L (API 21..32)
                @Suppress("DEPRECATION")
                override fun onCharacteristicRead(
                    gatt: BluetoothGatt,
                    characteristic: BluetoothGattCharacteristic,
                    status: Int
                ) {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                        handlePsmCharacteristicRead(gatt, device, characteristic.value, status, result.rssi)
                    }
                }

                // Compatible Android 13+ (API 33+)
                override fun onCharacteristicChanged(
                    gatt: BluetoothGatt,
                    characteristic: BluetoothGattCharacteristic,
                    value: ByteArray
                ) {
                    if (characteristic.uuid == gattPacketCharacteristicUuid) {
                        processIncomingGattChunk(gattEndpointId, value)
                    }
                }

                // Compatible Android 5.0 à 12L (API 21..32)
                @Suppress("DEPRECATION")
                override fun onCharacteristicChanged(
                    gatt: BluetoothGatt,
                    characteristic: BluetoothGattCharacteristic
                ) {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU &&
                        characteristic.uuid == gattPacketCharacteristicUuid
                    ) {
                        val value = characteristic.value ?: return
                        processIncomingGattChunk(gattEndpointId, value)
                    }
                }
            })
        }
    }

    @SuppressLint("MissingPermission", "deprecation")
    private fun handlePsmCharacteristicRead(
        gatt: BluetoothGatt,
        device: BluetoothDevice,
        value: ByteArray?,
        status: Int,
        rssi: Int
    ) {
        val l2capEndpointId = "ble:${device.address}"
        val gattEndpointId = "gatt:${device.address}"
        pendingGattConnections.remove(gattEndpointId)

        if (status != BluetoothGatt.GATT_SUCCESS || value == null || value.size < 2) {
            gatt.disconnect()
            return
        }

        val buf = ByteBuffer.wrap(value)
        val psm = buf.short.toInt() and 0xFFFF
        val peerBytes = ByteArray(buf.remaining())
        buf.get(peerBytes)
        val advertisedPeerId = if (peerBytes.isNotEmpty()) String(peerBytes, Charsets.UTF_8) else device.address

        // Si Android >= 10 (API 29) ET que le pair distant expose un PSM L2CAP > 0, on bascule sur L2CAP haute vitesse
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && psm > 0) {
            gatt.disconnect()
            connectL2capSocket(device, l2capEndpointId, psm, advertisedPeerId, rssi)
            return
        }

        // Sinon (Android 5.0..9.0 ou pair sans L2CAP), on active les notifications sur la caractéristique GATT 0000FD9C-...
        val packetChar = gatt.getService(serviceUuid)?.getCharacteristic(gattPacketCharacteristicUuid)
        if (packetChar == null) {
            gatt.disconnect()
            return
        }

        gatt.setCharacteristicNotification(packetChar, true)
        val cccd = packetChar.getDescriptor(cccdUuid)
        if (cccd != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            } else {
                cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                gatt.writeDescriptor(cccd)
            }
        }

        activeGattClients[gattEndpointId] = gatt
        emitEvent(
            mapOf(
                "event" to "peer_discovered",
                "endpointId" to gattEndpointId,
                "peerId" to advertisedPeerId,
                "displayName" to "Pair BLE ($advertisedPeerId)",
                "rssiDbm" to rssi,
                "medium" to "BLE GATT Universel (API 21+)",
                "isInitiator" to true
            )
        )
    }

    @SuppressLint("MissingPermission")
    private fun connectL2capSocket(
        device: BluetoothDevice,
        endpointId: String,
        psm: Int,
        advertisedPeerPrefix: String,
        rssi: Int
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || activeL2capSockets.containsKey(endpointId)) return
        ioExecutor.execute {
            try {
                val socket = device.createInsecureL2capChannel(psm)
                socket.connect()
                activeL2capSockets[endpointId] = socket
                emitEvent(
                    mapOf(
                        "event" to "peer_discovered",
                        "endpointId" to endpointId,
                        "peerId" to advertisedPeerPrefix,
                        "displayName" to "Pair BLE ($advertisedPeerPrefix)",
                        "rssiDbm" to rssi,
                        "medium" to "BLE L2CAP (Android <-> iOS)"
                    )
                )
                handleL2capSocketLoop(endpointId, socket)
            } catch (_: Exception) {
                // Échec d'ouverture du socket L2CAP
            }
        }
    }
}
