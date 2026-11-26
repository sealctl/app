package com.sealctl.app

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.StrictMode
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
        if (BuildConfig.DEBUG) strictMode()
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
                // Counted now: an onStop before this work runs leaves no socket open (SPEC.md 8.3).
                val turn = engine.started()
                engine.scope.launch {
                    engine.computePhase()
                    engine.onForeground(turn)
                }
            }

            override fun onStop(owner: LifecycleOwner) = engine.onBackground()
        })
    }

    /**
     * Debug builds only: disk and network use on the main thread are logged ("StrictMode" in
     * logcat), with the store's calls among them. The store is Rust (SQLite behind one lock),
     * which StrictMode cannot see by itself, so [safe] reports each call as a slow call.
     */
    private fun strictMode() {
        StrictMode.setThreadPolicy(
            StrictMode.ThreadPolicy.Builder().detectDiskReads().detectDiskWrites().detectNetwork().detectCustomSlowCalls()
                .penaltyLog().build(),
        )
    }

    override fun onPush(type: String, id: String?, expires: Long) = Graph.engine.onPush(type, id, expires)

    override fun onNewToken(token: String) {
        Graph.engine.scope.launch { Graph.engine.registerPush(token) }
    }

    override suspend fun onAction(requestId: String, action: String) = Graph.engine.answerFromNotification(requestId, action)

    override fun openIntent(context: Context, requestId: String?, screen: String?): Intent =
        OpenActivity.intent(context, requestId, screen)

    override fun onPlaceTransition(placeIds: List<String>, entered: Boolean) = Graph.engine.onPlaceTransition(placeIds, entered)

    override fun onPlacesUnavailable() = Graph.engine.onPlacesUnavailable()
}
