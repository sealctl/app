package com.sealctl.notify

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * FCM data-only, high-priority messages (SPEC.md 10.2): `type`, `id`, `expires`. The app
 * lists pending requests and builds the notification itself; nothing about the request goes
 * through Google.
 */
class SealctlMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val type = data["type"] ?: return
        val expires = data["expires"]?.toLongOrNull() ?: 0L
        (applicationContext as NotifyHost).onPush(type, data["id"], expires)
    }

    override fun onNewToken(token: String) {
        (applicationContext as NotifyHost).onNewToken(token)
    }
}
