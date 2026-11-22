package com.sealctl.places

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeoutOrNull

/** What the app does when the phone crosses a place's edge; the Application implements it. */
interface PlacesHost {
    fun onPlaceTransition(placeIds: List<String>, entered: Boolean)
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
class Places(private val context: Context) {
    private val geofencing = LocationServices.getGeofencingClient(context)
    private val fused = LocationServices.getFusedLocationProviderClient(context)

    fun hasForeground(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    fun hasBackground(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun pendingIntent(): PendingIntent = PendingIntent.getBroadcast(
        context, 0, Intent(context, GeofenceReceiver::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
    )

    /** Replaces the monitored geofences with these places. */
    @SuppressLint("MissingPermission")
    suspend fun monitor(fences: List<Fence>) {
        runCatching { geofencing.removeGeofences(pendingIntent()).await() }
        if (fences.isEmpty() || !hasForeground() || !hasBackground()) return
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
        runCatching { geofencing.addGeofences(request, pendingIntent()).await() }
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
        if (event.hasError()) return
        val ids = event.triggeringGeofences?.map { it.requestId } ?: return
        val entered = event.geofenceTransition == Geofence.GEOFENCE_TRANSITION_ENTER
        (context.applicationContext as? PlacesHost)?.onPlaceTransition(ids, entered)
    }
}
