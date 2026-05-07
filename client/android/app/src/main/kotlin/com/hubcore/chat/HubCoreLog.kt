package com.hubcore.chat

import android.util.Log
import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Unified file logger for all Kotlin (and forwarded Go) log lines.
 *
 * Writes to <filesDir>/hubcore.log alongside Flutter's FileLogger output.
 * File is opened in APPEND mode — Flutter clears it on startup first,
 * then Kotlin appends.
 *
 * Uses a background thread + queue to avoid blocking the caller.
 */
object HubCoreLog {
    private val fmt = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    private val queue = LinkedBlockingQueue<String>(4096)
    private val running = AtomicBoolean(false)
    private var writer: BufferedWriter? = null

    fun init(filesDir: File) {
        if (running.getAndSet(true)) return
        try {
            val file = File(filesDir, "hubcore.log")
            // Flutter already cleared it; open in append mode
            writer = BufferedWriter(FileWriter(file, true))
        } catch (e: Exception) {
            Log.w("HubCoreLog", "Failed to open log file: $e")
        }
        Thread({
            while (running.get() || queue.isNotEmpty()) {
                try {
                    val line = queue.poll(200, java.util.concurrent.TimeUnit.MILLISECONDS)
                        ?: continue
                    writer?.write(line)
                    writer?.newLine()
                    writer?.flush()
                } catch (_: Exception) {}
            }
        }, "HubCoreLog-writer").also { it.isDaemon = true; it.start() }
    }

    fun close() {
        running.set(false)
        writer?.close()
        writer = null
    }

    fun d(tag: String, msg: String) { log("D", tag, msg); Log.d(tag, msg) }
    fun i(tag: String, msg: String) { log("I", tag, msg); Log.i(tag, msg) }
    fun w(tag: String, msg: String, e: Throwable? = null) {
        log("W", tag, if (e != null) "$msg | $e" else msg)
        if (e != null) Log.w(tag, msg, e) else Log.w(tag, msg)
    }
    fun e(tag: String, msg: String, e: Throwable? = null) {
        log("E", tag, if (e != null) "$msg | $e" else msg)
        if (e != null) Log.e(tag, msg, e) else Log.e(tag, msg)
    }

    /** Forward a Go log line (already formatted) directly to file. */
    fun go(layer: String, line: String) {
        log("G", layer, line)
    }

    private fun log(level: String, tag: String, msg: String) {
        val ts = fmt.format(Date())
        queue.offer("$ts [$level/$tag] $msg")
    }
}
