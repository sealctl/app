package com.sealctl.app

import java.io.File
import java.io.FileOutputStream

/**
 * Erase (SPEC.md 11.19) removes the keys, then the database. A marker written before the keys
 * go, and removed once the database is gone too, lets the next start finish an erase that a
 * stop cut short: the keys may be gone already, but the database is not kept.
 */
internal class EraseMarker(private val file: File) {
    /** An erase began and did not finish. */
    val pending: Boolean get() = file.exists()

    /**
     * Runs [erase] with the marker written (and synced) first. The marker stays when [erase]
     * says it did not finish, so the next start runs it again. Returns what [erase] returned.
     */
    fun erasing(erase: () -> Boolean): Boolean {
        runCatching {
            file.parentFile?.mkdirs()
            FileOutputStream(file).use { it.write(1); it.fd.sync() }
        }
        val done = erase()
        if (done) file.delete()
        return done
    }

    /** At start: an erase that did not finish runs again. False when none was pending. */
    fun resume(erase: () -> Boolean): Boolean = pending && erasing(erase)
}
