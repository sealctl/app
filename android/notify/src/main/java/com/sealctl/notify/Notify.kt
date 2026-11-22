package com.sealctl.notify

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/** What the app does with pushes and notification actions; the Application implements it. */
interface NotifyHost {
    /** A push arrived: `type` `request`, `test`, `delayed` or `cancelled`. */
    fun onPush(type: String, id: String?, expires: Long)

    /** FCM gave a new token. */
    fun onNewToken(token: String)

    /** A notification action was tapped. Returns when the answer is posted or handed off. */
    suspend fun onAction(requestId: String, action: String)

    /** The activity that opens the app at a request or screen. */
    fun openIntent(context: Context, requestId: String?, screen: String?): Intent
}

/** One notification action. */
data class NoteAction(val id: String, val title: String, val authRequired: Boolean)

/** The notification for one request (SPEC.md 10.2). */
data class RequestNote(
    val requestId: String,
    val machine: String,
    val title: String,
    val body: String,
    val expires: Long,
    val actions: List<NoteAction>,
    /** Level 2 and 3, old words, unknown kinds: the `sensitive` channel, no actions. */
    val sensitive: Boolean,
)

/** Channels and notifications (SPEC.md 10.2). */
object Notify {
    const val REQUESTS = "requests"
    const val ANSWERED = "answered"
    const val PLACES = "places"
    const val CARD = "card"
    const val MACHINES = "machines"
    const val SENSITIVE = "sensitive"

    const val EXTRA_REQUEST = "com.sealctl.REQUEST"
    const val EXTRA_ACTION = "com.sealctl.ACTION"
    const val EXTRA_SCREEN = "com.sealctl.SCREEN"
    const val PUBLIC_TEXT = "A machine is waiting for your phone."

    fun createChannels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannels(
            listOf(
                NotificationChannel(REQUESTS, "Requests", NotificationManager.IMPORTANCE_HIGH),
                NotificationChannel(ANSWERED, "Answered by itself", NotificationManager.IMPORTANCE_MIN),
                NotificationChannel(PLACES, "Places", NotificationManager.IMPORTANCE_LOW),
                NotificationChannel(CARD, "Card and words", NotificationManager.IMPORTANCE_DEFAULT),
                NotificationChannel(MACHINES, "Machines", NotificationManager.IMPORTANCE_LOW),
                NotificationChannel(SENSITIVE, "Sensitive and leaving", NotificationManager.IMPORTANCE_HIGH),
            ),
        )
    }

    fun allowed(context: Context): Boolean =
        NotificationManagerCompat.from(context).areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)

    private fun host(context: Context) = context.applicationContext as NotifyHost

    private fun tagId(tag: String) = tag.hashCode()

    /** Shows a request: heads-up with actions, or a sensitive one that opens the app. */
    fun showRequest(context: Context, note: RequestNote) {
        if (!allowed(context)) return
        val open = PendingIntent.getActivity(
            context, tagId(note.requestId),
            host(context).openIntent(context, note.requestId, null),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val public = NotificationCompat.Builder(context, if (note.sensitive) SENSITIVE else REQUESTS)
            .setSmallIcon(R.drawable.ic_stat_sealctl)
            .setContentTitle(PUBLIC_TEXT)
            .build()
        val b = NotificationCompat.Builder(context, if (note.sensitive) SENSITIVE else REQUESTS)
            .setSmallIcon(R.drawable.ic_stat_sealctl)
            .setContentTitle(note.title)
            .setContentText(note.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(note.body))
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setContentIntent(open)
        val left = note.expires - System.currentTimeMillis()
        if (left > 0) b.setTimeoutAfter(left)
        // Android 9 to 11 have no unlock-first actions: the notification opens the card.
        if (!note.sensitive && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            for (a in note.actions) {
                val pi = PendingIntent.getBroadcast(
                    context, (note.requestId + a.id).hashCode(),
                    Intent(context, ApprovalActionReceiver::class.java)
                        .putExtra(EXTRA_REQUEST, note.requestId)
                        .putExtra(EXTRA_ACTION, a.id),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
                b.addAction(
                    NotificationCompat.Action.Builder(0, a.title, pi)
                        .setAuthenticationRequired(a.authRequired)
                        .build(),
                )
            }
        }
        notify(context, note.requestId, b.build())
    }

    /** A plain notification on a channel; `tag` replaces an earlier one. */
    fun show(context: Context, channel: String, tag: String, title: String, body: String?, timeoutMs: Long = 0, screen: String? = null) {
        if (!allowed(context)) return
        val open = PendingIntent.getActivity(
            context, tagId(tag), host(context).openIntent(context, null, screen),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val b = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_sealctl)
            .setContentTitle(title)
            .setAutoCancel(true)
            .setContentIntent(open)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        if (body != null) b.setContentText(body).setStyle(NotificationCompat.BigTextStyle().bigText(body))
        if (timeoutMs > 0) b.setTimeoutAfter(timeoutMs)
        notify(context, tag, b.build())
    }

    fun cancel(context: Context, tag: String) {
        NotificationManagerCompat.from(context).cancel(tag, tagId(tag))
    }

    @android.annotation.SuppressLint("MissingPermission")
    private fun notify(context: Context, tag: String, n: android.app.Notification) {
        if (!allowed(context)) return
        NotificationManagerCompat.from(context).notify(tag, tagId(tag), n)
    }
}
