package com.sealctl.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.launch

/** Boot and update re-register the geofences (SPEC.md 10.2). */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        Graph.engine.scope.launch {
            try { Graph.engine.monitorPlaces() } finally { pending.finish() }
        }
    }
}
