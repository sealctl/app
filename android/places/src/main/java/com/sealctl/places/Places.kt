package com.sealctl.places

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofenceStatusCodes
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeoutOrNull

/** What the app does when the phone crosses a place's edge; the Application implements it. */
interface PlacesHost {
    fun onPlaceTransition(placeIds: List<String>, entered: Boolean)

    /**
     * Location was turned off: the system dropped the geofences, so leaving a place would go
     * unnoticed. The place stops counting until the geofences are registered again. Not an exit.
     */
    fun onPlacesUnavailable() {}
}

/** The location permission the app has. [Places] reads the system's; tests give their own. */
interface LocationPermissions {
    /** Precise location while the app is in use. */
    fun hasForeground(): Boolean

    /** Location "Allow all the time" (Android 10 and later; before that, part of the foreground). */
    fun hasBackground(): Boolean
}

/** A trusted place to monitor. */
data class Fence(val id: String, val lat: Double, val lon: Double, val radius: Float)

/** One location fix. */
data class Fix(val lat: Double, val lon: Double, val accuracy: Double, val time: Long)

/**
 * Places on Android (SPEC.md 10.3, 11.9): one geofence per place with enter and exit, never
 * expiring, 2-minute responsiveness; one location fix at the first approval of the day.
 * Locations never leave the phone.
 */
class Places(private val context: Context) : LocationPermissions {
    private val geofencing = LocationServices.getGeofencingClient(context)
    private val fused = LocationServices.getFusedLocationProviderClient(context)

    override fun hasForeground(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    override fun hasBackground(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun intent() = Intent(context, GeofenceReceiver::class.java)

    private fun pendingIntent(): PendingIntent = PendingIntent.getBroadcast(
        context, 0, intent(), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
    )

    /**
     * The geofences this app registered are still in place: their PendingIntent still exists.
     * A reboot, a force stop or an app update cancels it, and the geofences with it; a process
     * the system ended for memory keeps both, and their exits still start the app. Read it before
     * [monitor] makes the PendingIntent again.
     */
    fun registrationAlive(): Boolean = PendingIntent.getBroadcast(
        context, 0, intent(), PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_MUTABLE,
    ) != null

    /**
     * Replaces the monitored geofences with these places. True when they are registered: places
     * exist and location is allowed all the time (geofences need it from Android 10).
     * [GeofencingRequest.INITIAL_TRIGGER_ENTER]: a phone already inside a place gets its enter
     * at once, so the current place comes back after every registration (app start, boot,
     * update, a change of places or of the permission).
     */
    @SuppressLint("MissingPermission")
    suspend fun monitor(fences: List<Fence>): Boolean {
        runCatching { geofencing.removeGeofences(pendingIntent()).await() }
        if (fences.isEmpty() || !hasForeground() || !hasBackground()) return false
        val request = GeofencingRequest.Builder()
            .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER)
            .addGeofences(
                fences.map {
                    Geofence.Builder()
                        .setRequestId(it.id)
                        .setCircularRegion(it.lat, it.lon, it.radius)
                        .setExpirationDuration(Geofence.NEVER_EXPIRE)
                        .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT)
                        .setNotificationResponsiveness(120_000)
                        .build()
                },
            )
            .build()
        return runCatching { geofencing.addGeofences(request, pendingIntent()).await() }.isSuccess
    }

    /** One fix within 10 seconds: balanced power first, high accuracy above 100 m. */
    @SuppressLint("MissingPermission")
    suspend fun sample(): Fix? {
        if (!hasForeground()) return null
        suspend fun get(priority: Int) = withTimeoutOrNull(10_000) {
            runCatching {
                fused.getCurrentLocation(
                    CurrentLocationRequest.Builder().setPriority(priority).setDurationMillis(10_000).build(), null,
                ).await()
            }.getOrNull()
        }
        var loc = get(Priority.PRIORITY_BALANCED_POWER_ACCURACY)
        if (loc == null || loc.accuracy > 100f) loc = get(Priority.PRIORITY_HIGH_ACCURACY) ?: loc
        return loc?.let { Fix(it.latitude, it.longitude, it.accuracy.toDouble(), it.time) }
    }
}

/** Geofence transitions. */
class GeofenceReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val event = GeofencingEvent.fromIntent(intent) ?: return
        if (event.hasError()) {
            if (event.errorCode == GeofenceStatusCodes.GEOFENCE_NOT_AVAILABLE) {
                (context.applicationContext as? PlacesHost)?.onPlacesUnavailable()
            }
            return
        }
        val ids = event.triggeringGeofences?.map { it.requestId } ?: return
        val entered = event.geofenceTransition == Geofence.GEOFENCE_TRANSITION_ENTER
        (context.applicationContext as? PlacesHost)?.onPlaceTransition(ids, entered)
    }
}

/**
 * The trusted place the phone was last inside, kept across process restarts (SPEC.md 11.9).
 * Android ends the app's process to free memory and starts it again for a push; the geofences
 * live on in the system, but an enter is not sent again. Without this the phone would not know
 * it is still at the place until it next crossed an edge. Only the place's id is kept, never a
 * location.
 */
class PlaceMemory(private val context: Context) {
    private val prefs = context.getSharedPreferences("places", Context.MODE_PRIVATE)

    /** What was saved: the place, and the boot it was saved in. */
    data class Saved(val place: String, val boot: Int)

    fun save(place: String) {
        prefs.edit().putString(PLACE, place).putInt(BOOT, bootCount(context)).apply()
    }

    fun clear() {
        prefs.edit().remove(PLACE).remove(BOOT).apply()
    }

    fun saved(): Saved? = prefs.getString(PLACE, null)?.let { Saved(it, prefs.getInt(BOOT, -1)) }

    companion object {
        private const val PLACE = "inside"
        private const val BOOT = "boot"

        /** The device's boot count; -1 where the system does not keep one. */
        fun bootCount(context: Context): Int =
            runCatching { Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1) }.getOrDefault(-1)

        /**
         * The place to count as current after a restart: the saved one only while every exit
         * from it would have been seen. That needs location all the time ([always]), the same
         * boot, the geofences still registered ([registered]: no reboot, force stop or update
         * since), and the place still trusted ([live]). Anything else: no place, until the
         * geofences' initial enter says so again.
         */
        fun restore(saved: Saved?, boot: Int, registered: Boolean, always: Boolean, live: Collection<String>): String? =
            saved?.takeIf { always && registered && it.boot == boot && it.place in live }?.place
    }
}
