package com.sealctl.app

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.sealctl.notify.Notify
import java.util.concurrent.TimeUnit

/** The one daily job (SPEC.md 10.3): prune, sync if due, refresh the FCM token. */
class DailyWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val e = Graph.engine
        if (e.phoneKeys() == null) return Result.success()
        safe { e.store.prune(e.clockNow().toULong(), e.offset()) }
        e.refreshState()
        if (e.local.value.dirty) e.upload()
        e.registerPush()
        return Result.success()
    }

    companion object {
        fun schedule(context: Context) {
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                "daily", ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<DailyWorker>(1, TimeUnit.DAYS).build(),
            )
        }
    }
}

/** "Ready: open sealctl to finish …" at the end of a level 3 delay on the phone (SPEC.md 10.1). */
class ReleaseWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val id = inputData.getString("id") ?: return Result.success()
        val what = inputData.getString("what") ?: "leave"
        // A cancel from a computer may not have reached this phone yet: ask the relay first.
        Graph.engine.refreshDelayed()
        val d = Graph.engine.local.value.delayed.firstOrNull { it.id == id }
        if (d == null || d.state == "cancelled") return Result.success()
        Notify.show(applicationContext, Notify.SENSITIVE, "ready-$id", Texts.ready(what), null, screen = "delayed:$id")
        return Result.success()
    }

    companion object {
        fun schedule(context: Context, id: String, what: String, releaseAt: Long) {
            WorkManager.getInstance(context).enqueueUniqueWork(
                "release-$id", ExistingWorkPolicy.REPLACE,
                OneTimeWorkRequestBuilder<ReleaseWorker>()
                    .setInitialDelay((releaseAt - System.currentTimeMillis()).coerceAtLeast(0), TimeUnit.MILLISECONDS)
                    .setInputData(workDataOf("id" to id, "what" to what))
                    .build(),
            )
        }
    }
}
