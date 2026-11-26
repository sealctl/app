package com.sealctl.app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import com.sealctl.core.app.DelayPhase
import com.sealctl.core.app.DelayedAction
import com.sealctl.core.app.delayPhase
import kotlinx.coroutines.launch

/**
 * Where the alarm of a "Ready" notification is set: [SystemReadyAlarms] in the app, a recorder
 * in the tests.
 */
interface ReadyAlarms {
    /** Whether an exact alarm may be set: always below Android 12, "Alarms & reminders" from 12. */
    fun canExact(): Boolean

    /** An alarm at [at] (Unix ms) for the action [id] of kind [what], replacing an earlier one. */
    fun set(id: String, what: String, at: Long, exact: Boolean)

    fun cancel(id: String)
}

/**
 * "Ready: open sealctl to …" at the end of a level 3 delay on the phone (SPEC.md 10.2, 11.23).
 *
 * The notification comes from an alarm at `releaseAt`, not from WorkManager, whose work can be
 * held back far past that time in Doze or app standby while the window to finish is an hour.
 * The alarm is exact (`setExactAndAllowWhileIdle`) when the app may set one, else
 * `setAndAllowWhileIdle`, which still fires in Doze, without a permission. Alarms do not survive
 * a reboot or a force stop, so they are set again at boot, after an update, when exact alarms
 * are allowed or taken away, and when the app starts.
 */
object Ready {
    /** The actions on the phone this install starts, and which tell when they are ready. */
    val KINDS = setOf("words", "delete", "leave")

    /** Set by [Graph.init]; tests put a recorder here. */
    @Volatile var alarms: ReadyAlarms? = null

    /** The notification's tag, which a cancel removes. */
    fun tag(id: String) = "ready-$id"

    fun schedule(id: String, what: String, releaseAt: Long) {
        val a = alarms ?: return
        a.set(id, what, releaseAt, a.canExact())
    }

    fun cancel(id: String) {
        alarms?.cancel(id)
    }

    /** An action this install started on the phone, which gets a "Ready" notification. */
    fun isOwn(d: DelayedAction): Boolean = d.machine == null && d.what in KINDS

    /**
     * Sets the alarms again ([alarms] lost them, or exact alarms were allowed since): one for
     * each action still waiting. Returns the ids already ready, whose notification is due now;
     * the caller posts it when the notification may have gone with the alarm (a reboot).
     */
    fun restore(delayed: List<DelayedAction>, now: Long): List<String> {
        val ready = mutableListOf<String>()
        for (d in delayed.filter(::isOwn)) {
            when (delayPhase(d, now.toULong())) {
                DelayPhase.WAITING -> schedule(d.id, d.what, d.releaseAt.toLong())
                DelayPhase.READY -> ready += d.id
                else -> cancel(d.id)
            }
        }
        return ready
    }
}

/** [ReadyAlarms] through `AlarmManager`; the alarm wakes [ReadyReceiver]. */
class SystemReadyAlarms(private val context: Context) : ReadyAlarms {
    private val alarmManager get() = context.getSystemService(AlarmManager::class.java)

    override fun canExact(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarmManager.canScheduleExactAlarms()

    override fun set(id: String, what: String, at: Long, exact: Boolean) {
        val pi = PendingIntent.getBroadcast(context, id.hashCode(), intent(id).putExtra(EXTRA_WHAT, what),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val am = alarmManager
        try {
            if (exact) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
        } catch (e: SecurityException) {
            // Exact alarms were taken away between the check and the call.
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
        }
    }

    override fun cancel(id: String) {
        val pi = PendingIntent.getBroadcast(context, id.hashCode(), intent(id),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_NO_CREATE) ?: return
        alarmManager.cancel(pi)
        pi.cancel()
    }

    /** Whether an alarm is set for [id] (instrumented tests). */
    fun isSet(id: String): Boolean =
        PendingIntent.getBroadcast(context, id.hashCode(), intent(id), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_NO_CREATE) != null

    /** One intent per action: the data makes them distinct, so one cancel removes only its own. */
    private fun intent(id: String): Intent =
        Intent(context, ReadyReceiver::class.java).setData(Uri.fromParts("sealctl-ready", id, null)).putExtra(EXTRA_ID, id)

    companion object {
        const val EXTRA_ID = "com.sealctl.READY_ID"
        const val EXTRA_WHAT = "com.sealctl.READY_WHAT"
    }
}

/**
 * The alarm at `releaseAt` (not exported: only the app's own PendingIntent reaches it). The
 * engine asks the relay first whether the action was cancelled, then posts "Ready".
 */
class ReadyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(SystemReadyAlarms.EXTRA_ID) ?: return
        val pending = goAsync()
        Graph.engine.scope.launch {
            try { Graph.engine.readyAlarm(id) } finally { pending.finish() }
        }
    }
}
