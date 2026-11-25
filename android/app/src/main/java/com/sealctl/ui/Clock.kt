package com.sealctl.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.sealctl.app.everyWhileStarted

/**
 * The time a screen shows ("Waiting · 0:42", "2 h left", "seen 1 min ago"), read again every
 * [periodMs] while the screen is on show. In the background it stops; it is read again the
 * moment the app comes back.
 */
@Composable
fun rememberNow(periodMs: Long = 1_000): State<Long> {
    val now = remember { mutableLongStateOf(System.currentTimeMillis()) }
    WhileStarted(periodMs) { now.longValue = System.currentTimeMillis() }
    return now
}

/**
 * Runs [block] at once and every [periodMs] while the screen is on show (its activity started),
 * not in the background; [keys] start it again. For a screen's countdown or relay check.
 */
@Composable
fun WhileStarted(periodMs: Long, vararg keys: Any?, block: suspend () -> Unit) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val current by rememberUpdatedState(block)
    LaunchedEffect(lifecycle, periodMs, *keys) {
        lifecycle.everyWhileStarted(periodMs) { current() }
    }
}
