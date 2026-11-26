package com.sealctl.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.launch

/**
 * Boot and update re-register the geofences and the "Ready" alarms, which a reboot clears;
 * exact alarms allowed or taken away set the alarms again (SPEC.md 10.2).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val boot = intent.action == Intent.ACTION_BOOT_COMPLETED
        Graph.engine.scope.launch {
            try {
                Graph.engine.restoreReadyAlarms(afterBoot = boot)
                if (intent.action != EXACT_ALARMS_CHANGED) Graph.engine.monitorPlaces()
            } finally {
                pending.finish()
            }
        }
    }

    companion object {
        const val EXACT_ALARMS_CHANGED = "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED"
    }
}
