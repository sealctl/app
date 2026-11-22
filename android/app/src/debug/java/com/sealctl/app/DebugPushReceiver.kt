package com.sealctl.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Debug builds only (SPEC.md 16.3): calls the push handler as if an FCM data message had
 * arrived, for tests against the fake relay, which sends no real pushes.
 *
 *   adb shell am broadcast -n com.sealctl.app/.DebugPushReceiver --es type request
 */
class DebugPushReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val type = intent.getStringExtra("type") ?: "request"
        Graph.engine.onPush(type, intent.getStringExtra("id"), intent.getLongExtra("expires", 0L))
    }
}
