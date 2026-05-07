package com.hubcore.chat

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Log

private const val DB_NAME    = "incoming_raw.db"
private const val DB_VERSION = 1
private const val TAG        = "IncomingRawDb"

/** Unencrypted buffer for incoming packets that arrived while Flutter was inactive.
 *
 *  Data is already Double-Ratchet encrypted by the sender — storing it plain is safe:
 *  without the session key the bytes are opaque. Metadata (from_pub, received_at)
 *  is visible on the network level anyway.
 *
 *  Flutter drains this table on startup / EventChannel reconnect and then deletes rows.
 */
class IncomingRawDb(context: Context) : SQLiteOpenHelper(
    context.applicationContext, DB_NAME, null, DB_VERSION
) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE incoming_raw (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                from_pub    TEXT    NOT NULL,
                data        BLOB    NOT NULL,
                received_at INTEGER NOT NULL
            )
        """.trimIndent())
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // No upgrades yet.
    }

    /** Insert one incoming packet. Called from YggdrasilService background thread. */
    fun insert(fromPub: String, data: ByteArray) {
        try {
            val now = System.currentTimeMillis() / 1000L
            val cv = ContentValues().apply {
                put("from_pub",    fromPub)
                put("data",        data)
                put("received_at", now)
            }
            writableDatabase.insert("incoming_raw", null, cv)
        } catch (e: Exception) {
            Log.w(TAG, "insert failed: ${e.message}")
        }
    }

    /** Return all buffered packets ordered by arrival time. */
    fun readAll(): List<RawPacket> {
        val result = mutableListOf<RawPacket>()
        try {
            readableDatabase.query(
                "incoming_raw", null, null, null, null, null, "received_at ASC"
            ).use { cursor ->
                val idxId       = cursor.getColumnIndexOrThrow("id")
                val idxFromPub  = cursor.getColumnIndexOrThrow("from_pub")
                val idxData     = cursor.getColumnIndexOrThrow("data")
                val idxRecvAt   = cursor.getColumnIndexOrThrow("received_at")
                while (cursor.moveToNext()) {
                    result.add(RawPacket(
                        id         = cursor.getLong(idxId),
                        fromPub    = cursor.getString(idxFromPub),
                        data       = cursor.getBlob(idxData),
                        receivedAt = cursor.getLong(idxRecvAt),
                    ))
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "readAll failed: ${e.message}")
        }
        return result
    }

    /** Delete rows by id. Called after Flutter successfully processes them. */
    fun deleteIds(ids: List<Long>) {
        if (ids.isEmpty()) return
        try {
            val placeholders = ids.joinToString(",") { "?" }
            writableDatabase.execSQL(
                "DELETE FROM incoming_raw WHERE id IN ($placeholders)",
                ids.map { it.toString() }.toTypedArray()
            )
        } catch (e: Exception) {
            Log.w(TAG, "deleteIds failed: ${e.message}")
        }
    }

    /** Delete rows older than [maxAgeSec] seconds (TTL cleanup). */
    fun deleteOlderThan(maxAgeSec: Long) {
        try {
            val cutoff = System.currentTimeMillis() / 1000L - maxAgeSec
            writableDatabase.delete("incoming_raw", "received_at < ?", arrayOf(cutoff.toString()))
        } catch (e: Exception) {
            Log.w(TAG, "deleteOlderThan failed: ${e.message}")
        }
    }
}

data class RawPacket(
    val id: Long,
    val fromPub: String,
    val data: ByteArray,
    val receivedAt: Long,
)
