package com.sealctl.app

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay

/**
 * Runs [block] at once and then every [periodMs], only while this lifecycle is at least
 * started: the countdowns and the relay checks of an open screen stop when the app leaves the
 * screen and start again, at once, when it comes back. Compose keeps an effect running while
 * its activity is merely stopped, so a plain `while (true)` loop would go on in the background.
 */
suspend fun Lifecycle.everyWhileStarted(periodMs: Long, block: suspend () -> Unit) {
    repeatOnLifecycle(Lifecycle.State.STARTED) {
        while (true) {
            block()
            delay(periodMs)
        }
    }
}
