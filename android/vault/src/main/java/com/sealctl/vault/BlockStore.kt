package com.sealctl.vault

import android.content.Context
import com.google.android.gms.auth.blockstore.Blockstore
import com.google.android.gms.auth.blockstore.DeleteBytesRequest
import com.google.android.gms.auth.blockstore.RetrieveBytesRequest
import com.google.android.gms.auth.blockstore.StoreBytesData
import kotlinx.coroutines.tasks.await

/**
 * The words backup in Block Store (SPEC.md 7.3): key `com.sealctl.words.v1`, the core's
 * backup item. Backed up to the cloud only when Google can end-to-end encrypt it.
 */
class BlockStore(context: Context) {
    private val client = Blockstore.getClient(context)

    suspend fun e2eeAvailable(): Boolean = runCatching { client.isEndToEndEncryptionAvailable.await() }.getOrDefault(false)

    /** Returns whether the copy goes to the cloud. */
    suspend fun save(item: ByteArray): Boolean {
        val cloud = e2eeAvailable()
        client.storeBytes(
            StoreBytesData.Builder().setKey(KEY).setBytes(item).setShouldBackupToCloud(cloud).build(),
        ).await()
        return cloud
    }

    suspend fun read(): ByteArray? = runCatching {
        client.retrieveBytes(RetrieveBytesRequest.Builder().setKeys(listOf(KEY)).build()).await()
            .blockstoreDataMap[KEY]?.bytes
    }.getOrNull()

    suspend fun delete() {
        runCatching { client.deleteBytes(DeleteBytesRequest.Builder().setKeys(listOf(KEY)).build()).await() }
    }

    companion object {
        const val KEY = "com.sealctl.words.v1"
    }
}
