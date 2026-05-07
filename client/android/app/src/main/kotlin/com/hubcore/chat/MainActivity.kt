package com.hubcore.chat

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Init Kotlin file logger — Flutter's FileLogger already cleared the file
        HubCoreLog.init(filesDir)
        HubCoreLog.i("MainActivity", "onCreate — HubCoreLog ready, filesDir=${filesDir.absolutePath}")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Security ──────────────────────────────────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hubcore/security",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecureFlag" -> {
                    val enable = call.arguments as? Boolean ?: true
                    if (enable) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    result.success(null)
                }
                // Hardware-backed Keystore is guaranteed on API 28+ (Android 9+).
                // On API 26-27 EncryptedSharedPreferences may use software Keystore.
                "isKeystoreHardwareBacked" -> {
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                }
                else -> result.notImplemented()
            }
        }

        // ── Yggdrasil control ─────────────────────────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hubcore/yggdrasil",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val privKeyHex         = call.argument<String>("privKeyHex") ?: ""
                    val peers              = call.argument<List<String>>("peers") ?: emptyList()
                    val listenAddr         = call.argument<String>("listenAddr") ?: "tls://0.0.0.0:0"
                    val allowedPubKeysJson = call.argument<String>("allowedPubKeysJson") ?: ""
                    val interfacePeersJson = call.argument<String>("interfacePeersJson") ?: ""
                    val intent = Intent(this, YggdrasilService::class.java).apply {
                        putExtra(YggdrasilService.EXTRA_PRIV_KEY, privKeyHex)
                        putExtra(YggdrasilService.EXTRA_PEERS, peers.toTypedArray())
                        putExtra(YggdrasilService.EXTRA_LISTEN, listenAddr)
                        putExtra(YggdrasilService.EXTRA_ALLOWED_PUBKEYS, allowedPubKeysJson)
                        putExtra(YggdrasilService.EXTRA_INTERFACE_PEERS, interfacePeersJson)
                    }
                    startForegroundService(intent)
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, YggdrasilService::class.java))
                    result.success(null)
                }
                "address"      -> result.success(YggdrasilService.node?.address())
                "publicKey"    -> result.success(YggdrasilService.node?.publicKeyHex())
                "privateKey"   -> result.success(YggdrasilService.node?.privateKeyHex())
                "peerCount"    -> result.success(YggdrasilService.node?.peerCount()?.toInt() ?: 0)
                "peersJson"    -> result.success(YggdrasilService.node?.peersJson() ?: "[]")
                "isRunning"    -> result.success(YggdrasilService.node != null)
                "listenPort"   -> result.success(YggdrasilService.node?.listenPort()?.toInt() ?: 0)
                "treeJson"     -> result.success(YggdrasilService.node?.treeJson() ?: "[]")
                "pathsJson"    -> result.success(YggdrasilService.node?.pathsJson() ?: "[]")
                "sessionsJson" -> result.success(YggdrasilService.node?.sessionsJson() ?: "[]")

                "addPeer" -> {
                    val uri = call.argument<String>("uri") ?: ""
                    Thread {
                        try {
                            YggdrasilService.node?.addPeer(uri)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("ADD_PEER_FAILED", e.message, null)
                        }
                    }.start()
                }

                "removePeer" -> {
                    val uri = call.argument<String>("uri") ?: ""
                    Thread {
                        try {
                            YggdrasilService.node?.removePeer(uri)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("REMOVE_PEER_FAILED", e.message, null)
                        }
                    }.start()
                }

                // Send raw bytes to a peer identified by their Ed25519 public key (hex)
                "send" -> {
                    val destPubKeyHex = call.argument<String>("destPubKeyHex") ?: ""
                    val data          = call.argument<ByteArray>("data")
                    if (data == null) {
                        result.error("INVALID_ARG", "data is required", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            YggdrasilService.node?.send(destPubKeyHex, data)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("SEND_FAILED", e.message, null)
                        }
                    }.start()
                }

                else -> result.notImplemented()
            }
        }

        // ── Battery optimization ──────────────────────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hubcore/battery",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoring" -> {
                    val pm = getSystemService(PowerManager::class.java)
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }
                "requestIgnore" -> {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    startActivity(intent)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // ── Connectivity info ─────────────────────────────────────────────────
        val cm = getSystemService(android.net.ConnectivityManager::class.java)

        fun currentNetworkType(): String {
            val nc = cm.getNetworkCapabilities(cm.activeNetwork)
            return when {
                nc == null -> "none"
                nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)     -> "wifi"
                nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET) -> "wifi"
                nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)      -> "vpn"
                nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
                else -> "other"
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hubcore/connectivity",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getNetworkType" -> result.success(currentNetworkType())
                else -> result.notImplemented()
            }
        }

        // Real-time network type stream — emits on every network change.
        io.flutter.plugin.common.EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hubcore/network_type",
        ).setStreamHandler(object : io.flutter.plugin.common.EventChannel.StreamHandler {
            private var cb: android.net.ConnectivityManager.NetworkCallback? = null

            override fun onListen(args: Any?, sink: io.flutter.plugin.common.EventChannel.EventSink?) {
                sink?.success(currentNetworkType()) // emit current state immediately
                cb = object : android.net.ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(n: android.net.Network) {
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            sink?.success(currentNetworkType())
                        }
                    }
                    override fun onLost(n: android.net.Network) {
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            sink?.success("none")
                        }
                    }
                    override fun onCapabilitiesChanged(
                        n: android.net.Network,
                        caps: android.net.NetworkCapabilities,
                    ) {
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            sink?.success(currentNetworkType())
                        }
                    }
                }
                cm.registerDefaultNetworkCallback(cb!!)
            }

            override fun onCancel(args: Any?) {
                cb?.let { try { cm.unregisterNetworkCallback(it) } catch (_: Exception) {} }
                cb = null
            }
        })

        // ── Incoming raw buffer control ───────────────────────────────────────
        // Flutter calls "ackPackets" with a list of row ids after processing them.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hubcore/incoming_raw",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "ackPackets" -> {
                    val ids = call.argument<List<Int>>("ids") ?: emptyList()
                    val db  = YggdrasilService.incomingRawDb
                    if (db != null && ids.isNotEmpty()) {
                        Thread { db.deleteIds(ids.map { it.toLong() }) }.start()
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // ── Reticulum control ─────────────────────────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hubcore/reticulum",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val configDir       = call.argument<String>("configDir") ?: ""
                    val identityPath    = call.argument<String>("identityPath") ?: ""
                    val tcpPeers        = call.argument<String>("tcpPeers") ?: ""
                    val enableAuto      = call.argument<Boolean>("enableAuto") ?: true
                    val enableTransport = call.argument<Boolean>("enableTransport") ?: false
                    val yggPeers        = call.argument<String>("yggPeers") ?: ""
                    val intent = Intent(this, ReticulumService::class.java).apply {
                        putExtra(ReticulumService.EXTRA_CONFIG_DIR, configDir)
                        putExtra(ReticulumService.EXTRA_IDENTITY_PATH, identityPath)
                        putExtra(ReticulumService.EXTRA_TCP_PEERS, tcpPeers)
                        putExtra(ReticulumService.EXTRA_ENABLE_AUTO, enableAuto)
                        putExtra(ReticulumService.EXTRA_ENABLE_TRANSPORT, enableTransport)
                        putExtra(ReticulumService.EXTRA_YGG_PEERS, yggPeers)
                    }
                    startForegroundService(intent)
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, ReticulumService::class.java))
                    result.success(null)
                }
                "address"    -> result.success(ReticulumService.node?.address() ?: "")
                "publicKey"  -> result.success(ReticulumService.node?.publicKeyHex() ?: "")
                "isRunning"  -> result.success(ReticulumService.node != null)
                "hasPath" -> {
                    val hash = call.argument<String>("destHash") ?: ""
                    result.success(ReticulumService.node?.hasPath(hash) ?: false)
                }
                "requestPath" -> {
                    val hash = call.argument<String>("destHash") ?: ""
                    ReticulumService.node?.requestPath(hash)
                    result.success(null)
                }
                "hopsTo" -> {
                    val hash = call.argument<String>("destHash") ?: ""
                    result.success(ReticulumService.node?.hopsTo(hash)?.toInt() ?: -1)
                }
                "announce" -> {
                    ReticulumService.node?.announce()
                    result.success(null)
                }
                "interfaceCount" -> {
                    result.success(ReticulumService.node?.interfaceCount()?.toInt() ?: 0)
                }
                "send" -> {
                    val destHash = call.argument<String>("destHash") ?: ""
                    val data     = call.argument<ByteArray>("data")
                    if (data == null) {
                        result.error("INVALID_ARG", "data is required", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            ReticulumService.node?.send(destHash, data)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("SEND_FAILED", e.message, null)
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        // ── Reticulum incoming messages (EventChannel → Flutter stream) ───────
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hubcore/reticulum/incoming",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                ReticulumService.incomingEventSink = events
            }
            override fun onCancel(arguments: Any?) {
                ReticulumService.incomingEventSink = null
            }
        })

        // ── Yggdrasil incoming messages (EventChannel → Flutter stream) ───────
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hubcore/yggdrasil/incoming",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                YggdrasilService.incomingEventSink = events
                // Drain packets persisted to disk while Flutter was inactive.
                val db = YggdrasilService.incomingRawDb ?: return
                Thread {
                    val packets = db.readAll()
                    if (packets.isEmpty()) return@Thread
                    android.util.Log.d("MainActivity", "Draining ${packets.size} buffered packet(s) from disk")
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        // Each packet carries its db row id so Flutter can ack via
                        // hubcore/incoming_raw ackPackets after processing.
                        for (p in packets) {
                            events.success(mapOf(
                                "from"       to p.fromPub,
                                "data"       to p.data,
                                "raw_buf_id" to p.id,
                            ))
                        }
                    }
                }.start()
            }
            override fun onCancel(arguments: Any?) {
                YggdrasilService.incomingEventSink = null
            }
        })
    }
}
