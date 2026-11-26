package com.sealctl.ui

import android.Manifest
import android.os.Build
import android.os.SystemClock
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.sealctl.app.Graph
import com.sealctl.app.PlaceRules
import com.sealctl.app.Texts
import com.sealctl.designsystem.Banner
import com.sealctl.designsystem.Body
import com.sealctl.designsystem.Muted
import com.sealctl.designsystem.PlainButton
import com.sealctl.designsystem.PrimaryButton
import com.sealctl.designsystem.Title
import kotlinx.coroutines.launch

/**
 * Asks for location "Allow all the time" the Android way (SPEC.md 11.3 step 9, 11.9): precise
 * location first if it is missing, then the background permission, which on Android 11 and
 * later opens the app's location page in the system settings. When the system shows nothing
 * (asked and declined before), the app's settings open instead. [onDone] runs after, with
 * whether location is now allowed all the time; the geofences are then registered.
 */
@Composable
fun rememberAllowAllTheTime(onDone: (Boolean) -> Unit = {}): () -> Unit {
    val engine = Graph.engine
    val context = ctx()
    val scope = rememberCoroutineScope()
    var asked by remember { mutableLongStateOf(0L) }
    // Answered at once: the system showed nothing, so the person goes to the settings themselves.
    fun shownNothing() = SystemClock.elapsedRealtime() - asked < 500
    fun finish(always: Boolean) {
        if (always) scope.launch { engine.monitorPlaces() }
        onDone(always)
    }
    val background = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (!granted && shownNothing()) openAppSettings(context)
        finish(granted)
    }
    fun askBackground() {
        asked = SystemClock.elapsedRealtime()
        background.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
    }
    val foreground = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { r ->
        when {
            r[Manifest.permission.ACCESS_FINE_LOCATION] != true -> {
                if (shownNothing()) openAppSettings(context)
                finish(false)
            }
            // Before Android 10 precise location includes the background.
            Build.VERSION.SDK_INT < 29 -> finish(true)
            // A second request right after the first: Android asks for the background on its own page.
            else -> askBackground()
        }
    }
    return {
        if (!engine.places.hasForeground()) {
            asked = SystemClock.elapsedRealtime()
            foreground.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
        } else if (Build.VERSION.SDK_INT >= 29 && !engine.places.hasBackground()) {
            askBackground()
        } else {
            finish(true)
        }
    }
}

/**
 * "Places need location set to “Allow all the time”…" on the Machines and Settings tabs while a
 * trusted place exists and location is not allowed all the time (SPEC.md 11.9). The permission
 * is read again each time the app comes back, as from the settings.
 */
@Composable
fun PlacesAlwaysBanner() {
    val engine = Graph.engine
    val state by engine.state.collectAsState()
    var access by remember { mutableStateOf(engine.location()) }
    LifecycleResumeEffect(Unit) {
        access = engine.location()
        onPauseOrDispose {}
    }
    val allow = rememberAllowAllTheTime { access = engine.location() }
    if (PlaceRules.needsAlways(access, state.places)) {
        Banner(Texts.PLACES_ALWAYS) { TextButton(allow) { Text("Open settings") } }
    }
}

/**
 * The explanation before the system's page, after the first trusted place when location is not
 * allowed all the time (SPEC.md 11.9), and in onboarding (11.3 step 9).
 */
@Composable
fun PlacesAlwaysScreen(onDone: () -> Unit) {
    val allow = rememberAllowAllTheTime { onDone() }
    Page(null, onBack = null, bottom = {
        PrimaryButton("Open settings", allow)
        PlainButton("Not now", onDone)
    }) {
        Spacer(Modifier.height(32.dp))
        Title(Texts.PLACES_ALWAYS_TITLE)
        Body(Texts.PLACES_ALWAYS_BODY)
        Muted(Texts.PLACES_ALWAYS_HOW)
        Muted("Without it, a session stays open up to 1 hour and reopening always takes a tap.")
    }
}
