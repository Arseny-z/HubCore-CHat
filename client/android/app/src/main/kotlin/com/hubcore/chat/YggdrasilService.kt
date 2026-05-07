package com.hubcore.chat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.os.IBinder
import android.os.PowerManager
import io.flutter.plugin.common.EventChannel
import yggbind.MessageHandler
import yggbind.Node
import yggbind.Yggbind
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

private const val TAG               = "YggdrasilService"
private const val NOTIF_MSG_CHANNEL = "hubcore_messages"
private const val NOTIF_MSG_ID      = 1002

/** Watchdog: if peer count stays 0 for this many consecutive ticks → restart peers. */
private const val WATCHDOG_ZERO_TICKS_RESTART = 3   // 3 × 30s = 90s
/** Watchdog: hard-restart the whole node after this many ticks with 0 peers. */
private const val WATCHDOG_ZERO_TICKS_HARD    = 10  // 10 × 30s = 5 min
private const val TICKER_INTERVAL_SEC         = 30L

class YggdrasilService : Service() {

    companion object {
        var node: Node? = null
            private set

        const val EXTRA_PRIV_KEY       = "priv_key_hex"
        const val EXTRA_PEERS          = "peers"
        const val EXTRA_LISTEN          = "listen_addr"
        const val EXTRA_ALLOWED_PUBKEYS = "allowed_pubkeys_json"
        const val EXTRA_INTERFACE_PEERS = "interface_peers_json"

        // Shared notification id — owned by YggdrasilService, updated by both services.
        const val SHARED_NOTIF_ID      = 1001
        const val SHARED_NOTIF_CHANNEL = "hubcore_status"

        // EventChannel sink — set by MainActivity, used to push incoming messages to Flutter
        var incomingEventSink: EventChannel.EventSink? = null

        // Persistent buffer for packets that arrived while Flutter was inactive.
        // Backed by IncomingRawDb (plain SQLite on disk) — survives process restarts.
        // Initialized in onCreate(), drained by MainActivity on EventChannel.onListen().
        var incomingRawDb: IncomingRawDb? = null

        fun updateSharedNotification(context: android.content.Context, yggLine: String? = null) {
            val text = yggLine ?: if (node != null) {
                val c = node!!.peerCount().toInt()
                if (c > 0) "Yggdrasil · $c peers" else "Yggdrasil · connecting…"
            } else "Yggdrasil · off"
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.notify(SHARED_NOTIF_ID, buildSharedNotification(context, text))
        }

        fun buildSharedNotification(context: android.content.Context, text: String): android.app.Notification {
            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?.apply { addFlags(android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP) }
            val tapIntent = android.app.PendingIntent.getActivity(
                context, 0,
                launchIntent,
                android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT
            )
            return android.app.Notification.Builder(context, SHARED_NOTIF_CHANNEL)
                .setContentTitle("HubCore Chat")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentIntent(tapIntent)
                .setOngoing(true)
                .build()
        }
    }

    // WakeLock: held briefly while processing each incoming message.
    private lateinit var wakeLock: PowerManager.WakeLock

    // Startup params — kept for watchdog hard-restart.
    private var savedPrivKeyHex: String         = ""
    private var savedListenAddr: String         = "tls://0.0.0.0:0"
    private var savedAllowedPubKeysJson: String = ""
    private var savedInterfacePeersJson: String = ""
    private var configuredPeers: Array<String> = emptyArray()

    private var zeroPeerTicks = 0

    private val scheduler: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            HubCoreLog.i(TAG, "Network available — reconnecting peers")
            reconnectPeers()
            zeroPeerTicks = 0
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        val pm = getSystemService(PowerManager::class.java)
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "hubcore:incoming_message"
        ).apply { setReferenceCounted(false) }
        incomingRawDb = IncomingRawDb(this).also {
            // TTL: drop packets older than 7 days — DR session will be desynced by then.
            it.deleteOlderThan(7L * 24 * 3600)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val prefs = getSharedPreferences("ygg_service", MODE_PRIVATE)

        val privKeyHex: String
        val peers: Array<String>
        val listenAddr: String
        val allowedPubKeysJson: String
        val interfacePeersJson: String

        if (intent != null) {
            // Normal start from Flutter — read params and persist for sticky restart.
            privKeyHex         = intent.getStringExtra(EXTRA_PRIV_KEY) ?: ""
            peers              = intent.getStringArrayExtra(EXTRA_PEERS) ?: emptyArray()
            listenAddr         = intent.getStringExtra(EXTRA_LISTEN) ?: "tls://0.0.0.0:0"
            allowedPubKeysJson = intent.getStringExtra(EXTRA_ALLOWED_PUBKEYS) ?: ""
            interfacePeersJson = intent.getStringExtra(EXTRA_INTERFACE_PEERS) ?: ""

            if (privKeyHex.isNotEmpty()) {
                prefs.edit()
                    .putString(EXTRA_PRIV_KEY, privKeyHex)
                    .putString(EXTRA_PEERS, peers.joinToString("\n"))
                    .putString(EXTRA_LISTEN, listenAddr)
                    .putString(EXTRA_ALLOWED_PUBKEYS, allowedPubKeysJson)
                    .putString(EXTRA_INTERFACE_PEERS, interfacePeersJson)
                    .apply()
                HubCoreLog.i(TAG, "Startup params saved to SharedPreferences")
            }
        } else {
            // START_STICKY restart — intent is null, restore from SharedPreferences.
            HubCoreLog.i(TAG, "Restarted by system (intent=null) — restoring params from SharedPreferences")
            privKeyHex         = prefs.getString(EXTRA_PRIV_KEY, "") ?: ""
            val peersStr       = prefs.getString(EXTRA_PEERS, "") ?: ""
            peers              = if (peersStr.isNotEmpty()) peersStr.split("\n").toTypedArray() else emptyArray()
            listenAddr         = prefs.getString(EXTRA_LISTEN, "tls://0.0.0.0:0") ?: "tls://0.0.0.0:0"
            allowedPubKeysJson = prefs.getString(EXTRA_ALLOWED_PUBKEYS, "") ?: ""
            interfacePeersJson = prefs.getString(EXTRA_INTERFACE_PEERS, "") ?: ""

            if (privKeyHex.isEmpty()) {
                HubCoreLog.w(TAG, "No saved params — cannot start node, waiting for Flutter")
                startForeground(SHARED_NOTIF_ID, buildSharedNotification(this, "Yggdrasil · waiting for app…"))
                return START_STICKY
            }
        }

        savedPrivKeyHex          = privKeyHex
        savedListenAddr          = listenAddr
        savedAllowedPubKeysJson  = allowedPubKeysJson
        savedInterfacePeersJson  = interfacePeersJson
        configuredPeers          = peers

        startForeground(SHARED_NOTIF_ID, buildSharedNotification(this, "Yggdrasil · connecting…"))

        Thread {
            try {
                if (node == null) {
                    HubCoreLog.i(TAG, "Starting Yggdrasil node… listen=$listenAddr")
                    node = Yggbind.start(privKeyHex, listenAddr,
                        allowedPubKeysJson, interfacePeersJson)
                    HubCoreLog.i(TAG, "Node address: ${node?.address()}")
                    val port = node?.listenPort() ?: 0
                    if (port > 0) HubCoreLog.i(TAG, "Listening on port $port")

                    for (peer in peers) addPeerSafe(peer)

                    // Start receiving immediately so tree announcements are not missed.
                    node?.setLogHandler(GoLogHandler())
                    node?.startReceiving(IncomingHandler())

                    // Diagnostic: log routing tree + peer status after 10s (non-blocking).
                    Thread.sleep(10_000)
                    val treeSize = node?.treeJson()?.let {
                        org.json.JSONArray(it).length()
                    } ?: 0
                    HubCoreLog.i(TAG, "Routing tree size after 10s: $treeSize")
                    node?.peersJson()?.let { json ->
                        try {
                            val arr = org.json.JSONArray(json)
                            for (i in 0 until arr.length()) {
                                val p = arr.getJSONObject(i)
                                HubCoreLog.i(TAG, "Peer: up=${p.optBoolean("up")} uri=${p.optString("uri").take(40)} err=${p.optString("last_error").take(60)}")
                            }
                        } catch (_: Exception) {}
                    }
                }
            } catch (e: Exception) {
                HubCoreLog.e(TAG, "Failed to start Yggdrasil node: ${e.message}")
            }
        }.start()

        // Register network change callback.
        val cm = getSystemService(ConnectivityManager::class.java)
        cm.registerDefaultNetworkCallback(networkCallback)

        // Periodic ticker: update notification + watchdog.
        scheduler.scheduleAtFixedRate(::tick, TICKER_INTERVAL_SEC, TICKER_INTERVAL_SEC, TimeUnit.SECONDS)

        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Called when user swipes the app from recent tasks.
        // Flutter EventChannel onCancel is NOT called in this case — clear sink manually.
        HubCoreLog.i(TAG, "onTaskRemoved — clearing incomingEventSink")
        incomingEventSink = null
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        scheduler.shutdownNow()
        val cm = getSystemService(ConnectivityManager::class.java)
        try { cm.unregisterNetworkCallback(networkCallback) } catch (_: Exception) {}
        if (wakeLock.isHeld) wakeLock.release()
        node?.stop()
        node = null
        HubCoreLog.i(TAG, "Yggdrasil node stopped")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── Ticker (notification + watchdog) ──────────────────────────────────────

    private fun tick() {
        val n = node ?: return
        val count = n.peerCount().toInt()

        // Update shared notification with live peer count.
        updateNotification(if (count > 0) "Yggdrasil · $count peers" else "Yggdrasil · reconnecting…")

        // Watchdog logic.
        if (count > 0) {
            zeroPeerTicks = 0
            return
        }
        zeroPeerTicks++
        HubCoreLog.w(TAG, "Watchdog: 0 peers for $zeroPeerTicks tick(s)")

        when {
            zeroPeerTicks >= WATCHDOG_ZERO_TICKS_HARD -> {
                HubCoreLog.w(TAG, "Watchdog: hard-restarting Yggdrasil node")
                zeroPeerTicks = 0
                hardRestart()
            }
            zeroPeerTicks >= WATCHDOG_ZERO_TICKS_RESTART -> {
                HubCoreLog.w(TAG, "Watchdog: re-adding all peers")
                reconnectPeers()
            }
        }
    }

    // ── Peer management ───────────────────────────────────────────────────────

    private fun addPeerSafe(peer: String) {
        try {
            node?.addPeer(resolveHostInPeerUri(peer))
            HubCoreLog.i(TAG, "Added peer: $peer")
        } catch (e: Exception) {
            HubCoreLog.w(TAG, "Failed to add peer $peer: ${e.message}")
        }
    }

    /**
     * Resolves the hostname in a peer URI to an IP address using Android DNS.
     * Go's net package on Android 10 cannot use the system DNS resolver, so we
     * pre-resolve hostnames in Kotlin before passing URIs to the Go layer.
     * Example: "tls://ekb.itrus.su:7992" → "tls://92.248.252.139:7992"
     */
    private fun resolveHostInPeerUri(uri: String): String {
        return try {
            val u = java.net.URI(uri)
            val host = u.host ?: return uri
            // Skip if already an IP address
            if (host.matches(Regex("\\d+\\.\\d+\\.\\d+\\.\\d+"))) return uri
            val ip = java.net.InetAddress.getByName(host).hostAddress ?: return uri
            val resolved = java.net.URI(u.scheme, u.userInfo, ip, u.port, u.path, u.query, u.fragment)
            resolved.toString()
        } catch (_: Exception) {
            uri // fallback to original if resolution fails
        }
    }

    /** Re-add all configured peers (soft reconnect — node stays running). */
    private fun reconnectPeers() {
        val n = node ?: return
        for (peer in configuredPeers) {
            try { n.removePeer(peer) } catch (_: Exception) {}
            addPeerSafe(peer)
        }
    }

    /** Stop and restart the entire Yggdrasil node (hard reset). */
    private fun hardRestart() {
        try {
            node?.stop()
        } catch (_: Exception) {}
        node = null

        try {
            node = Yggbind.start(savedPrivKeyHex, savedListenAddr,
                savedAllowedPubKeysJson, savedInterfacePeersJson)
            HubCoreLog.i(TAG, "Hard-restart: node address ${node?.address()}")
            for (peer in configuredPeers) addPeerSafe(peer)
            node?.setLogHandler(GoLogHandler())
            node?.startReceiving(IncomingHandler())
        } catch (e: Exception) {
            HubCoreLog.e(TAG, "Hard-restart failed: ${e.message}")
        }
    }

    // ── Notification ──────────────────────────────────────────────────────────

    private fun createNotificationChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        // IMPORTANCE_MIN: no status-bar icon, collapsed to bottom of shade — barely visible.
        nm.createNotificationChannel(
            NotificationChannel(
                SHARED_NOTIF_CHANNEL, "HubCore Chat", NotificationManager.IMPORTANCE_MIN
            ).apply {
                description = "Keeps HubCore Chat connected to the network"
                setShowBadge(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(
                NOTIF_MSG_CHANNEL, "HubCore Messages", NotificationManager.IMPORTANCE_HIGH
            ).apply { description = "Incoming HubCore Chat messages" }
        )
    }

    private fun updateNotification(yggLine: String) {
        updateSharedNotification(this, yggLine = yggLine)
    }

    // ── Go log handler ────────────────────────────────────────────────────────

    private inner class GoLogHandler : yggbind.LogHandler {
        override fun onLog(line: String) = HubCoreLog.go("YGG", line)
    }

    // ── Incoming message handler ──────────────────────────────────────────────

    private inner class IncomingHandler : MessageHandler {
        // 16 MB — larger payloads are dropped to prevent OOM from malicious peers.
        private val MAX_PACKET_BYTES = 16 * 1024 * 1024

        override fun onMessage(fromPubKeyHex: String, data: ByteArray) {
            if (data.size > MAX_PACKET_BYTES) {
                HubCoreLog.w(TAG, "Dropping oversized packet from $fromPubKeyHex: ${data.size} bytes > $MAX_PACKET_BYTES limit")
                return
            }

            HubCoreLog.d(TAG, "Incoming message from $fromPubKeyHex (${data.size} bytes)")
            // Acquire WakeLock so CPU stays awake while Flutter processes the message.
            // Timeout 10s — released after delivery to EventChannel or on timeout.
            wakeLock.acquire(10_000L)
            val sink = incomingEventSink
            HubCoreLog.d(TAG, "incomingEventSink=${if (sink != null) "active" else "null (Flutter closed)"}")
            if (sink == null) {
                // Flutter is not active — persist the packet to disk so it survives
                // process restarts, then notify the user to open the app.
                incomingRawDb?.insert(fromPubKeyHex, data)
                // Try to extract mid from the plaintext JSON envelope and send msg_received.
                // DM wire format: {"c":"...","n":N,"id":"<mid>", ...}
                // "id" is plaintext — Kotlin can read it without decrypting "c".
                val isDm = trySendMsgReceived(fromPubKeyHex, data)
                // Only show notification for real DM messages (has "id" field).
                // System packets (contact_hello, cert_update, etc.) have no "id" — skip.
                if (isDm) showNewMessageNotification()
                wakeLock.release()
                return
            }
            HubCoreLog.d(TAG, "Delivering to Flutter via EventChannel")
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                try {
                    sink.success(mapOf("from" to fromPubKeyHex, "data" to data))
                } catch (e: Exception) {
                    // Flutter process was killed (swipe from recents) without calling onCancel.
                    // Treat sink as dead — buffer the packet and send msg_received.
                    HubCoreLog.w(TAG, "EventSink dead (Flutter killed?): ${e.message} — buffering packet")
                    incomingEventSink = null
                    incomingRawDb?.insert(fromPubKeyHex, data)
                    showNewMessageNotification()
                    trySendMsgReceived(fromPubKeyHex, data)
                } finally {
                    if (wakeLock.isHeld) wakeLock.release()
                }
            }
        }
    }

    /**
     * Parses the plaintext JSON envelope to extract "id" (mid) and sends a
     * raw msg_received packet back to the sender so they know the message
     * arrived on this device even while the app is closed.
     *
     * The receipt is a plain JSON string (not DR-encrypted) sent directly
     * via the Yggdrasil node.  The sender's Flutter layer handles it as a
     * raw system packet.
     */
    /** Returns true if this was a real DM (has "id"), false for system packets. */
    private fun trySendMsgReceived(fromPubKeyHex: String, data: ByteArray): Boolean {
        try {
            val raw = String(data, Charsets.UTF_8)
            HubCoreLog.d(TAG, "trySendMsgReceived: raw prefix=${raw.take(80)}")
            val outer = org.json.JSONObject(raw)

            // Wire format: {"from":"...","to":"...","body":"<base64 of DmPayload JSON>"}
            // DmPayload JSON: {"c":"...","n":N,"id":"<mid>", ...}
            val bodyBase64 = outer.optString("body").takeIf { it.isNotEmpty() }
            val json = if (bodyBase64 != null) {
                try {
                    val bodyBytes = android.util.Base64.decode(bodyBase64, android.util.Base64.DEFAULT)
                    org.json.JSONObject(String(bodyBytes, Charsets.UTF_8))
                } catch (e: Exception) {
                    HubCoreLog.d(TAG, "trySendMsgReceived: body is not JSON (encrypted box), skipping")
                    return false
                }
            } else {
                outer
            }

            val mid = json.optString("id").takeIf { it.isNotEmpty() }
            if (mid == null) {
                HubCoreLog.d(TAG, "trySendMsgReceived: no 'id' field — not a DM, skipping")
                return false
            }
            val receipt = """{"type":"msg_received","mid":"$mid"}""".toByteArray(Charsets.UTF_8)
            val n = node
            if (n == null) {
                HubCoreLog.w(TAG, "trySendMsgReceived: node is null, cannot send receipt")
                return true // it IS a DM, just couldn't send receipt
            }
            n.send(fromPubKeyHex, receipt)
            HubCoreLog.i(TAG, "msg_received sent: mid=${mid.take(8)}… to ${fromPubKeyHex.take(16)}…")
            return true
        } catch (e: Exception) {
            HubCoreLog.w(TAG, "trySendMsgReceived failed: ${e.message}")
            return false
        }
    }

    private fun showNewMessageNotification() {
        val tapIntent = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification = Notification.Builder(this, NOTIF_MSG_CHANNEL)
            .setContentTitle("HubCore Chat")
            .setContentText("New message")
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentIntent(tapIntent)
            .setAutoCancel(true)
            .build()
        getSystemService(NotificationManager::class.java).notify(NOTIF_MSG_ID, notification)
    }
}
