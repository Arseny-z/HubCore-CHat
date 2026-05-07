package com.hubcore.chat

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager
import rnsbind.Rnsbind
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

private const val TAG = "ReticulumService"
/** Watchdog: ticker interval. */
private const val TICKER_INTERVAL_SEC = 30L

/**
 * Foreground service that runs the Reticulum node.
 *
 * Full parity with YggdrasilService:
 * - START_STICKY: persists params to SharedPreferences, restores after system kill
 * - Watchdog: periodic health check, hard restart on failure
 * - msg_received: sends receipt back to sender while Flutter is inactive
 * - Push notification: shows "New message" when Flutter is in background
 * - IncomingRawDb: persists packets to disk, drained when Flutter reconnects
 */
class ReticulumService : Service() {

    companion object {
        const val EXTRA_CONFIG_DIR       = "configDir"
        const val EXTRA_IDENTITY_PATH    = "identityPath"
        const val EXTRA_TCP_PEERS        = "tcpPeers"
        const val EXTRA_ENABLE_AUTO      = "enableAuto"
        const val EXTRA_ENABLE_TRANSPORT = "enableTransport"
        const val EXTRA_YGG_PEERS        = "yggPeers"  // comma-separated [200:...]:port list

        private const val MAX_PACKET_BYTES = 16 * 1024 * 1024

        var node: rnsbind.Node? = null
            private set

        @Volatile
        var incomingEventSink: io.flutter.plugin.common.EventChannel.EventSink? = null

        var incomingRawDb: IncomingRawDb? = null
    }

    private lateinit var wakeLock: PowerManager.WakeLock
    private val scheduler: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()

    // Saved for START_STICKY restart.
    private var savedConfigDir: String        = ""
    private var savedIdentityPath: String     = ""
    private var savedTcpPeers: String         = ""
    private var savedEnableAuto: Boolean      = true
    private var savedEnableTransport: Boolean = false
    private var savedYggPeers: String         = ""

    // Re-announce when network becomes available so RNS path discovery
    // recovers quickly after WiFi→mobile or reconnection.
    private val networkCallback = object : android.net.ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: android.net.Network) {
            val n = node ?: return
            HubCoreLog.i(TAG, "Network available — re-announcing RNS destinations")
            Thread { try { n.announce() } catch (_: Exception) {} }.start()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannels()
        if (incomingRawDb == null) {
            incomingRawDb = IncomingRawDb(this).also {
                it.deleteOlderThan(7L * 24 * 3600)
            }
        }
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "hubcore:reticulum")
            .apply { setReferenceCounted(false) }
    }

    /** Create notification channels if not yet created (may start before YggdrasilService). */
    private fun ensureNotificationChannels() {
        val nm = getSystemService(android.app.NotificationManager::class.java)
        if (nm.getNotificationChannel(YggdrasilService.SHARED_NOTIF_CHANNEL) == null) {
            nm.createNotificationChannel(
                android.app.NotificationChannel(
                    YggdrasilService.SHARED_NOTIF_CHANNEL, "HubCore Chat",
                    android.app.NotificationManager.IMPORTANCE_MIN
                ).apply {
                    description = "Keeps HubCore Chat connected to the network"
                    setShowBadge(false)
                }
            )
        }
        if (nm.getNotificationChannel("hubcore_messages") == null) {
            nm.createNotificationChannel(
                android.app.NotificationChannel(
                    "hubcore_messages", "HubCore Messages",
                    android.app.NotificationManager.IMPORTANCE_HIGH
                ).apply { description = "Incoming HubCore Chat messages" }
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (node != null) {
            HubCoreLog.d(TAG, "Node already running")
            return START_STICKY
        }

        val prefs = getSharedPreferences("rns_service", MODE_PRIVATE)

        val configDir: String
        val identityPath: String
        val tcpPeers: String
        val enableAuto: Boolean
        val enableTransport: Boolean
        val yggPeers: String

        if (intent != null) {
            configDir       = intent.getStringExtra(EXTRA_CONFIG_DIR).let { if (it.isNullOrEmpty()) filesDir.resolve("rns_config").absolutePath else it }
            identityPath    = intent.getStringExtra(EXTRA_IDENTITY_PATH).let { if (it.isNullOrEmpty()) filesDir.resolve("rns_identity").absolutePath else it }
            tcpPeers        = intent.getStringExtra(EXTRA_TCP_PEERS) ?: ""
            enableAuto      = intent.getBooleanExtra(EXTRA_ENABLE_AUTO, true)
            enableTransport = intent.getBooleanExtra(EXTRA_ENABLE_TRANSPORT, false)
            yggPeers        = intent.getStringExtra(EXTRA_YGG_PEERS) ?: ""

            // Persist for sticky restart.
            prefs.edit()
                .putString(EXTRA_CONFIG_DIR, configDir)
                .putString(EXTRA_IDENTITY_PATH, identityPath)
                .putString(EXTRA_TCP_PEERS, tcpPeers)
                .putBoolean(EXTRA_ENABLE_AUTO, enableAuto)
                .putBoolean(EXTRA_ENABLE_TRANSPORT, enableTransport)
                .putString(EXTRA_YGG_PEERS, yggPeers)
                .apply()
        } else {
            // START_STICKY restart — restore from SharedPreferences.
            HubCoreLog.i(TAG, "Restarted by system — restoring params")
            configDir       = prefs.getString(EXTRA_CONFIG_DIR, filesDir.resolve("rns_config").absolutePath) ?: ""
            identityPath    = prefs.getString(EXTRA_IDENTITY_PATH, filesDir.resolve("rns_identity").absolutePath) ?: ""
            tcpPeers        = prefs.getString(EXTRA_TCP_PEERS, "") ?: ""
            enableAuto      = prefs.getBoolean(EXTRA_ENABLE_AUTO, true)
            enableTransport = prefs.getBoolean(EXTRA_ENABLE_TRANSPORT, false)
            yggPeers        = prefs.getString(EXTRA_YGG_PEERS, "") ?: ""
        }

        savedConfigDir       = configDir
        savedIdentityPath    = identityPath
        savedTcpPeers        = tcpPeers
        savedEnableAuto      = enableAuto
        savedEnableTransport = enableTransport
        savedYggPeers        = yggPeers

        startForeground(
            YggdrasilService.SHARED_NOTIF_ID,
            YggdrasilService.buildSharedNotification(this, "Reticulum · starting…")
        )

        Thread {
            try {
                // Wait up to 20s for Yggdrasil to start so bridges can be opened
                // before RNS starts — avoids needing to restart RNS later.
                if (yggPeers.isNotEmpty()) {
                    var waited = 0
                    while (YggdrasilService.node == null && waited < 20_000) {
                        Thread.sleep(500)
                        waited += 500
                    }
                }

                // Open TCP bridges for Yggdrasil-addressed RNS nodes (no VPN needed).
                val bridgePeers = openYggBridges(yggPeers)
                if (bridgePeers.isNotEmpty()) bridgesAttached = true
                val allTcpPeers = listOf(tcpPeers, bridgePeers)
                    .filter { it.isNotEmpty() }.joinToString(",")

                HubCoreLog.i(TAG, "Starting RNS node: config=$configDir tcp=${allTcpPeers.split(",").size} peers auto=$enableAuto")
                val n = Rnsbind.start(configDir, identityPath, allTcpPeers, enableAuto, enableTransport)
                n.setLogHandler(GoLogHandler("RNS"))
                n.startReceiving(IncomingHandler())
                node = n
                HubCoreLog.i(TAG, "RNS node started, address=${n.address()}")
                updateNotification("Reticulum · ${n.address().take(8)}…")
            } catch (e: Exception) {
                HubCoreLog.e(TAG, "Failed to start RNS node", e)
            }
        }.start()

        // Periodic health check.
        scheduler.scheduleAtFixedRate(::tick, TICKER_INTERVAL_SEC, TICKER_INTERVAL_SEC, TimeUnit.SECONDS)

        // Re-announce on network changes (path recovery after WiFi↔mobile switch).
        getSystemService(android.net.ConnectivityManager::class.java)
            .registerDefaultNetworkCallback(networkCallback)

        return START_STICKY
    }

    override fun onDestroy() {
        try {
            getSystemService(android.net.ConnectivityManager::class.java)
                .unregisterNetworkCallback(networkCallback)
        } catch (_: Exception) {}
        scheduler.shutdownNow()
        if (wakeLock.isHeld) wakeLock.release()
        node?.stop()
        node = null
        HubCoreLog.i(TAG, "RNS node stopped")
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        HubCoreLog.i(TAG, "onTaskRemoved — clearing EventSink")
        incomingEventSink = null
        super.onTaskRemoved(rootIntent)
    }

    // ── Ticker / watchdog ────────────────────────────────────────────────────

    private var failedTicks    = 0
    private var bridgesAttached = false

    private fun tick() {
        val n = node
        if (n == null || !n.isRunning) {
            failedTicks++
            HubCoreLog.w(TAG, "Watchdog: node down for $failedTicks tick(s)")
            if (failedTicks >= 5) { // 5 × 30s = 2.5 min
                HubCoreLog.w(TAG, "Watchdog: hard-restarting RNS node")
                failedTicks = 0
                bridgesAttached = false
                hardRestart()
            }
            updateNotification("Reticulum · reconnecting…")
            return
        }
        failedTicks = 0
        updateNotification("Reticulum · ${n.address().take(8)}…")

    }

    private fun hardRestart() {
        bridgesAttached = false
        hardRestartWithExtraPeers("")
    }

    private fun hardRestartWithExtraPeers(extraPeers: String) {
        try { node?.stop() } catch (_: Exception) {}
        node = null
        try {
            val allPeers = listOf(savedTcpPeers, extraPeers)
                .filter { it.isNotEmpty() }.joinToString(",")
            val n = Rnsbind.start(savedConfigDir, savedIdentityPath,
                allPeers, savedEnableAuto, savedEnableTransport)
            n.setLogHandler(GoLogHandler("RNS"))
            n.startReceiving(IncomingHandler())
            node = n
            HubCoreLog.i(TAG, "Hard-restart OK, address=${n.address()}")
        } catch (e: Exception) {
            HubCoreLog.e(TAG, "Hard-restart failed: ${e.message}")
        }
    }

    /**
     * Opens TCP bridges for each Yggdrasil-addressed RNS peer using the
     * wireguard userspace netstack inside yggbind. No VPN required.
     *
     * Input: comma-separated "[200:...]:port" strings (brackets optional).
     * Returns: comma-separated "127.0.0.1:PORT" strings for the RNS TCP peer list.
     */
    private fun openYggBridges(yggPeers: String): String {
        if (yggPeers.isBlank()) return ""
        val yggNode = YggdrasilService.node ?: run {
            HubCoreLog.d(TAG, "Yggdrasil not running — skipping Ygg RNS bridges")
            return ""
        }
        val localPorts = mutableListOf<String>()
        for (raw in yggPeers.split(",")) {
            val peer = raw.trim().takeIf { it.isNotEmpty() } ?: continue
            try {
                // Parse [addr]:port  or  addr:port
                val lastColon = peer.lastIndexOf(':')
                if (lastColon < 0) continue
                val portStr = peer.substring(lastColon + 1)
                val addrPart = peer.substring(0, lastColon)
                    .trimStart('[').trimEnd(']')
                val remotePort = portStr.toIntOrNull() ?: continue

                val localPort = yggNode.openTCPBridge(addrPart, remotePort.toLong())
                if (localPort > 0) {
                    localPorts.add("127.0.0.1:$localPort")
                    HubCoreLog.i(TAG, "Ygg bridge: [$addrPart]:$remotePort → 127.0.0.1:$localPort")
                }
            } catch (e: Exception) {
                HubCoreLog.w(TAG, "Ygg bridge failed for $peer: ${e.message}")
            }
        }
        return localPorts.joinToString(",")
    }

    private fun updateNotification(text: String) {
        try {
            YggdrasilService.updateSharedNotification(this, text)
        } catch (_: Exception) {}
    }

    // ── Go log handler ────────────────────────────────────────────────────────

    private inner class GoLogHandler(private val layer: String) : rnsbind.LogHandler {
        override fun onLog(line: String) {
            // Suppress high-frequency "tcp iface offline/detached" warnings — these fire
            // every second for every disconnected TCP peer (normal RNS Jobs-loop behaviour)
            // and add no diagnostic value once the initial connection errors are seen.
            if (line.contains("tcp iface offline/detached") || line.contains("TCP send error")) return
            HubCoreLog.go(layer, line)
        }
    }

    // ── Incoming message handler ──────────────────────────────────────────────

    private inner class IncomingHandler : rnsbind.MessageHandler {
        override fun onMessage(fromHashHex: String, data: ByteArray) {
            if (data.size > MAX_PACKET_BYTES) {
                HubCoreLog.w(TAG, "Dropping oversized packet from $fromHashHex: ${data.size} bytes")
                return
            }
            HubCoreLog.d(TAG, "Incoming from $fromHashHex (${data.size} bytes)")
            wakeLock.acquire(10_000L)

            val sink = incomingEventSink
            if (sink == null) {
                // Flutter inactive — buffer to disk + show notification.
                incomingRawDb?.insert(fromHashHex, data)
                showNewMessageNotification()
                if (wakeLock.isHeld) wakeLock.release()
                return
            }

            android.os.Handler(android.os.Looper.getMainLooper()).post {
                try {
                    sink.success(mapOf(
                        "from"      to fromHashHex,
                        "data"      to data,
                        "transport" to "reticulum",
                    ))
                } catch (e: Exception) {
                    HubCoreLog.w(TAG, "EventSink dead: ${e.message} — buffering")
                    incomingEventSink = null
                    incomingRawDb?.insert(fromHashHex, data)
                    showNewMessageNotification()
                } finally {
                    if (wakeLock.isHeld) wakeLock.release()
                }
            }
        }
    }

    private fun showNewMessageNotification() {
        try {
            val tapIntent = PendingIntent.getActivity(
                this, 0,
                packageManager.getLaunchIntentForPackage(packageName),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val notification = Notification.Builder(this, "hubcore_messages")
                .setContentTitle("HubCore Chat")
                .setContentText("New message")
                .setSmallIcon(android.R.drawable.ic_dialog_email)
                .setContentIntent(tapIntent)
                .setAutoCancel(true)
                .build()
            getSystemService(NotificationManager::class.java).notify(1003, notification)
        } catch (_: Exception) {}
    }
}
