package com.sealctl.app

import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.tasks.await

/** The FCM token, when Firebase is configured in this build. */
object Push {
    suspend fun token(): String? =
        if (BuildConfig.HAS_FIREBASE) runCatching { FirebaseMessaging.getInstance().token.await() }.getOrNull() else null

    suspend fun renew(): String? {
        if (!BuildConfig.HAS_FIREBASE) return null
        runCatching { FirebaseMessaging.getInstance().deleteToken().await() }
        return token()
    }
}
