package com.sealctl.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** Notification actions (SPEC.md 10.2): answers within 9 seconds, else the host hands off. */
class ApprovalActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(Notify.EXTRA_REQUEST) ?: return
        val action = intent.getStringExtra(Notify.EXTRA_ACTION) ?: return
        val pending = goAsync()
        val host = context.applicationContext as NotifyHost
        Notify.cancel(context, id)
        scope.launch {
            try {
                withTimeoutOrNull(9_000) { host.onAction(id, action) }
            } finally {
                pending.finish()
            }
        }
    }

    private companion object {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }
}
