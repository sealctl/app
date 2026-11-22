package com.sealctl.designsystem

import android.provider.Settings
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

val CardShape = RoundedCornerShape(12.dp)

/** Filled with the accent: the primary action. */
@Composable
fun PrimaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    Button(
        onClick = onClick,
        enabled = enabled,
        shape = CardShape,
        colors = ButtonDefaults.buttonColors(containerColor = Sealctl.colors.accent, contentColor = Sealctl.colors.onAccent),
        modifier = modifier.fillMaxWidth().heightIn(min = 52.dp),
    ) { Text(text, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center) }
}

/** Outlined: secondary actions. */
@Composable
fun SecondaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        shape = CardShape,
        border = BorderStroke(1.dp, Sealctl.colors.ink2.copy(alpha = 0.4f)),
        colors = ButtonDefaults.outlinedButtonColors(contentColor = Sealctl.colors.ink),
        modifier = modifier.fillMaxWidth().heightIn(min = 52.dp),
    ) { Text(text, textAlign = TextAlign.Center) }
}

/** A plain text button: Deny, Cancel, Later. */
@Composable
fun PlainButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, color: Color = Sealctl.colors.ink2) {
    TextButton(onClick = onClick, modifier = modifier.fillMaxWidth().heightIn(min = 48.dp)) {
        Text(text, color = color)
    }
}

/** The wordmark: `sealctl`, lower case, monospace, weight 600. */
@Composable
fun Wordmark(modifier: Modifier = Modifier, size: Int = 28) {
    Text("sealctl", style = monoStyle(size, FontWeight.SemiBold), color = Sealctl.colors.ink, modifier = modifier)
}

@Composable
fun Mono(text: String, modifier: Modifier = Modifier, size: Int = 15, color: Color = Sealctl.colors.ink, weight: FontWeight = FontWeight.Normal) {
    // Names, commands and paths are never translated and always read left to right (SPEC.md 13).
    Text("⁦$text⁩", style = monoStyle(size, weight), color = color, modifier = modifier)
}

@Composable
fun SurfaceCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Card(
        modifier = modifier.fillMaxWidth(),
        shape = CardShape,
        colors = CardDefaults.cardColors(containerColor = Sealctl.colors.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
    ) { Column(Modifier.padding(16.dp), content = content) }
}

/** A fact on the approval card: muted label, monospace value. */
@Composable
fun Fact(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 3.dp)) {
        Text(label, color = Sealctl.colors.muted, modifier = Modifier.width(64.dp))
        Mono(value, size = 14)
    }
}

enum class MachineState { Locked, Open, Waiting, Unknown }

/** The state dot. Waiting pulses unless the system asks for less motion. */
@Composable
fun StateDot(state: MachineState, modifier: Modifier = Modifier) {
    val c = Sealctl.colors
    val color = when (state) {
        MachineState.Open -> c.open
        MachineState.Waiting -> c.waiting
        else -> c.muted
    }
    val reduceMotion = Settings.Global.getFloat(
        LocalContext.current.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f,
    ) == 0f
    val alpha = if (state == MachineState.Waiting && !reduceMotion) {
        val t = rememberInfiniteTransition(label = "pulse")
        val a by t.animateFloat(1f, 0.3f, infiniteRepeatable(tween(800), RepeatMode.Reverse), label = "a")
        a
    } else 1f
    Box(modifier.size(10.dp).alpha(alpha).background(color, CircleShape))
}

@Composable
fun StateLabel(state: MachineState, text: String) {
    val c = Sealctl.colors
    val color = when (state) {
        MachineState.Open -> c.open
        MachineState.Waiting -> c.waiting
        else -> c.muted
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        StateDot(state)
        Text(text, color = color, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}

/** A banner on top of a tab: offline, limits, waiting, delays. */
@Composable
fun Banner(text: String, modifier: Modifier = Modifier, tone: Color = Sealctl.colors.surface2, action: (@Composable () -> Unit)? = null) {
    Row(
        modifier.fillMaxWidth().background(tone, CardShape).padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, Modifier.weight(1f), fontSize = 14.sp, color = Sealctl.colors.ink)
        if (action != null) {
            Spacer(Modifier.width(8.dp))
            action()
        }
    }
}

@Composable
fun Title(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.headlineSmall, color = Sealctl.colors.ink, modifier = modifier.semantics { contentDescription = text })
}

@Composable
fun Body(text: String, modifier: Modifier = Modifier, color: Color = Sealctl.colors.ink2) {
    Text(text, style = MaterialTheme.typography.bodyLarge, color = color, modifier = modifier)
}

@Composable
fun Muted(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.bodyMedium, color = Sealctl.colors.muted, modifier = modifier)
}
