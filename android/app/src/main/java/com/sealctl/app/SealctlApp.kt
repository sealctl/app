package com.sealctl.app

import android.app.Application
import android.content.Context
import android.content.Intent
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.sealctl.notify.Notify
import com.sealctl.notify.NotifyHost
import com.sealctl.places.PlacesHost
import kotlinx.coroutines.launch

class SealctlApp : Application(), NotifyHost, PlacesHost {
    override fun onCreate() {
        super.onCreate()
        Graph.init(this)
        Notify.createChannels(this)
        DailyWorker.schedule(this)
        val engine = Graph.engine
        engine.scope.launch {
            engine.computePhase()
            engine.monitorPlaces()
            // Debug builds only: the FCM token, so the bench can send a test push before pairing.
            if (BuildConfig.DEBUG) Push.token()?.let { dlog("fcm token $it") }
        }
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                engine.scope.launch {
                    engine.computePhase()
                    engine.onForeground()
                }
            }

            override fun onStop(owner: LifecycleOwner) = engine.onBackground()
        })
    }

    override fun onPush(type: String, id: String?, expires: Long) = Graph.engine.onPush(type, id, expires)

    override fun onNewToken(token: String) {
        Graph.engine.scope.launch { Graph.engine.registerPush(token) }
    }

    override suspend fun onAction(requestId: String, action: String) = Graph.engine.answerFromNotification(requestId, action)

    override fun openIntent(context: Context, requestId: String?, screen: String?): Intent =
        Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .apply {
                if (requestId != null) putExtra(Notify.EXTRA_REQUEST, requestId)
                if (screen != null) putExtra(Notify.EXTRA_SCREEN, screen)
            }

    override fun onPlaceTransition(placeIds: List<String>, entered: Boolean) = Graph.engine.onPlaceTransition(placeIds, entered)
}
