package com.sealctl.ui

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import com.sealctl.app.Ui
import com.sealctl.designsystem.Sealctl

/** A screen with a title bar and a back arrow. */
@Composable
fun Page(title: String?, onBack: (() -> Unit)? = { Ui.pop() }, bottom: (@Composable ColumnScope.() -> Unit)? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().background(Sealctl.colors.paper).safeDrawingPadding()) {
        if (onBack != null || title != null) {
            Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                if (onBack != null) {
                    IconButton(onClick = onBack, modifier = Modifier.semantics { contentDescription = "Back" }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null, tint = Sealctl.colors.ink)
                    }
                } else Spacer(Modifier.width(16.dp))
                if (title != null) Text(title, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = Sealctl.colors.ink)
            }
        }
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            content = content,
        )
        if (bottom != null) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp), content = bottom)
        }
    }
}

/** Marks a screen that shows words: FLAG_SECURE while it is up (SPEC.md 11.21). */
@Composable
fun SecureScreen() {
    DisposableEffect(Unit) {
        Ui.secure.value += 1
        onDispose { Ui.secure.value -= 1 }
    }
}

@Composable
fun SectionLabel(text: String) {
    Text(text.uppercase(), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Sealctl.colors.muted, modifier = Modifier.padding(top = 12.dp))
}

@Composable
fun Gap(h: Int = 8) = Spacer(Modifier.height(h.dp))

fun openAppSettings(context: android.content.Context) {
    context.startActivity(
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
    )
}

fun openUrl(context: android.content.Context, url: String) {
    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
}

@Composable
fun ErrorText(text: String?) {
    if (text != null) Text(text, color = Sealctl.colors.accent, fontSize = 15.sp)
}

@Composable
fun Pill(text: String, modifier: Modifier = Modifier) {
    Box(modifier.background(Sealctl.colors.surface2, RoundedCornerShape(8.dp)).padding(horizontal = 8.dp, vertical = 2.dp)) {
        Text(text, fontSize = 12.sp, color = Sealctl.colors.ink2)
    }
}

@Composable
fun ctx() = LocalContext.current

val ContentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp)

@Suppress("unused")
private fun unused(i: ImageVector) = Modifier.size(1.dp)
