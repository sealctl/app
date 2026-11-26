package com.sealctl.app

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
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
