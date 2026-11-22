package com.sealctl.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sealctl.core.app.wordEntry
import com.sealctl.designsystem.Sealctl
import com.sealctl.designsystem.monoStyle

/**
 * The in-app word keypad (SPEC.md 11.4): letters a to z and delete, so no system keyboard
 * sees the words. Letters that cannot continue a BIP39 word are disabled; four letters that
 * name a word complete it.
 */
@Composable
fun WordKeypad(prefix: String, onChange: (String) -> Unit, onWord: (String) -> Unit) {
    val entry = remember(prefix) { wordEntry(prefix) }
    val rows = listOf("qwertyuiop", "asdfghjkl", "zxcvbnm")
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        for (row in rows) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally)) {
                for (c in row) {
                    val enabled = entry.nextLetters.contains(c.toString())
                    Key(c.toString(), enabled, Modifier.weight(1f)) {
                        val next = prefix + c
                        val e = wordEntry(next)
                        val done = e.completed
                        if (done != null && next.length >= 4) onWord(done) else if (done != null && done == next) onWord(done) else onChange(next)
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Key("delete", prefix.isNotEmpty(), Modifier.weight(1f)) { onChange(prefix.dropLast(1)) }
            Key(if (entry.exact) "✓ $prefix" else "✓", entry.exact || entry.completed != null, Modifier.weight(1f)) {
                onWord(if (entry.exact) prefix else entry.completed ?: prefix)
            }
        }
    }
}

@Composable
private fun Key(label: String, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val c = Sealctl.colors
    Box(
        modifier
            .heightIn(min = 48.dp)
            .background(if (enabled) c.surface else c.surface2, RoundedCornerShape(8.dp))
            .border(BorderStroke(1.dp, c.border), RoundedCornerShape(8.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .semantics { contentDescription = "key $label" },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = monoStyle(18, FontWeight.Medium), color = if (enabled) c.ink else c.muted.copy(alpha = 0.4f))
    }
}

/** One numbered field of typed words. */
@Composable
fun WordField(number: Int, value: String, focused: Boolean, error: Boolean, onClick: () -> Unit) {
    val c = Sealctl.colors
    Row(
        Modifier.fillMaxWidth()
            .background(if (focused) c.accentSoft else c.surface, RoundedCornerShape(8.dp))
            .border(BorderStroke(1.dp, if (error) c.accent else c.border), RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp)
            .semantics { contentDescription = "Word $number" },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("$number", style = monoStyle(14), color = c.muted, modifier = Modifier.width(32.dp))
        Text(value.ifEmpty { "____" }, style = monoStyle(18, FontWeight.Medium), color = c.ink)
    }
}

@Composable
fun ChoiceButton(text: String, onClick: () -> Unit) {
    OutlinedButton(onClick = onClick, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp), shape = RoundedCornerShape(12.dp)) {
        Text(text, style = monoStyle(18), color = Sealctl.colors.ink, fontSize = 18.sp)
    }
}
