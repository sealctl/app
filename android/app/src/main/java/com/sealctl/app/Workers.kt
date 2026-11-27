package com.sealctl.app

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
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

/**
 * Sends the locks and notices that wait in the outbox (SPEC.md 9.6) once their wait is over and
 * the phone is online, also after this process is gone: a lock on leaving a place goes from a
 * geofence broadcast the system ends soon after.
 */
class OutboxWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        Graph.engine.flushOutbox()
        return Result.success()
    }

    companion object {
        fun schedule(context: Context, delayMs: Long) {
            WorkManager.getInstance(context).enqueueUniqueWork(
                "outbox", ExistingWorkPolicy.REPLACE,
                OneTimeWorkRequestBuilder<OutboxWorker>()
                    .setInitialDelay(delayMs, TimeUnit.MILLISECONDS)
                    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                    .build(),
            )
        }
    }
}
