package com.sealctl.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import com.sealctl.notify.Notify

/**
 * Where a notification tap lands (SPEC.md 10.2). Not exported, so only the app's own
 * PendingIntents can start it: it hands the request or screen to [MainActivity] in memory and
 * finishes. [MainActivity] is exported as the launcher and ignores extras, so another app
 * cannot steer it to a request, a report or a delayed approval.
 */
class OpenActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Ui.opening.value = Ui.Open(intent.getStringExtra(Notify.EXTRA_REQUEST), intent.getStringExtra(Notify.EXTRA_SCREEN))
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        )
        finish()
    }

    companion object {
        /** The intent a notification opens: this activity, with the request or the screen. */
        fun intent(context: Context, requestId: String?, screen: String?): Intent =
            Intent(context, OpenActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .apply {
                    if (requestId != null) putExtra(Notify.EXTRA_REQUEST, requestId)
                    if (screen != null) putExtra(Notify.EXTRA_SCREEN, screen)
                }
    }
}
