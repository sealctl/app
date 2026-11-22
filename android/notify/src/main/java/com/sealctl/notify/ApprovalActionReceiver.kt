package com.sealctl.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Notification actions (SPEC.md 10.2): the receiver waits up to 9 seconds for the answer. The
 * request notification stays until the host has posted the answer (it cancels it then), so an
 * answer that fails, or is still going when the receiver has to finish, leaves it to tap again.
 */
class ApprovalActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(Notify.EXTRA_REQUEST) ?: return
        val action = intent.getStringExtra(Notify.EXTRA_ACTION) ?: return
        // A second tap while the first answer is on its way does nothing.
        if (!inFlight.add(id)) return
        val pending = goAsync()
        val host = context.applicationContext as NotifyHost
        // Not cancelled at 9 s: the answer keeps going for as long as the process lives.
        val work = scope.launch {
            try { host.onAction(id, action) } finally { inFlight.remove(id) }
        }
        scope.launch {
            try {
                withTimeoutOrNull(9_000) { work.join() }
            } finally {
                pending.finish()
            }
        }
    }

    private companion object {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val inFlight: MutableSet<String> = ConcurrentHashMap.newKeySet()
    }
}
