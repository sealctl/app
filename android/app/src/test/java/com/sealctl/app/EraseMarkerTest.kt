package com.sealctl.app

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Erase (SPEC.md 11.19): an erase that a stop cuts short is finished at the next start. */
class EraseMarkerTest {
    private val file = Files.createTempDirectory("erase").resolve("erasing").toFile()

    @Test
    fun anEraseStoppedAfterTheKeysIsFinishedAtTheNextStart() {
        val steps = mutableListOf<String>()
        // The process ends after the keys are gone, before the database (an exception stands in for the stop).
        runCatching {
            EraseMarker(file).erasing {
                assertTrue("the marker is written before the keys go", file.exists())
                steps += "keys"
                throw IllegalStateException("stopped")
            }
        }
        assertTrue(EraseMarker(file).pending)
        // The next start.
        assertTrue(EraseMarker(file).resume { steps += "keys"; steps += "database"; true })
        assertEquals(listOf("keys", "keys", "database"), steps)
        assertFalse(file.exists())
    }

    @Test
    fun aFinishedEraseLeavesNothingToResume() {
        assertTrue(EraseMarker(file).erasing { true })
        assertFalse(file.exists())
        var ran = false
        assertFalse(EraseMarker(file).resume { ran = true; true })
        assertFalse(ran)
    }

    @Test
    fun aDatabaseThatCouldNotBeErasedIsTriedAgain() {
        assertFalse(EraseMarker(file).erasing { false })
        assertTrue(EraseMarker(file).pending)
        assertTrue(EraseMarker(file).resume { true })
        assertFalse(EraseMarker(file).pending)
    }
}
