package com.sealctl.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import com.sealctl.app.Ui
import com.sealctl.designsystem.Body
import com.sealctl.designsystem.Mono
import com.sealctl.designsystem.Sealctl

/**
 * Settings → About → Licences (SPEC.md 11.18): the app's own licences, then every third-party
 * notice, generated at build time (app/build.gradle.kts `androidNotices`, notices/ for Rust).
 * Lazy, because the full texts run to thousands of lines.
 */
@Composable
fun LicencesScreen() {
    val context = ctx()
    val blocks = remember {
        listOf("notices/android-libraries.txt", "notices/rust-crates.txt").flatMap { path ->
            val text = runCatching { context.assets.open(path).bufferedReader().use { it.readText() } }.getOrDefault("")
            // one block per paragraph, so no single Text is thousands of lines long
            text.split(Regex("\n\\s*\n")).map { it.trimEnd() }.filter { it.isNotBlank() }
        }
    }
    Column(Modifier.fillMaxSize().background(Sealctl.colors.paper).safeDrawingPadding()) {
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { Ui.pop() }, modifier = Modifier.semantics { contentDescription = "Back" }) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null, tint = Sealctl.colors.ink)
            }
            Text("Licences", fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = Sealctl.colors.ink)
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp)) {
            item { Body("sealctl app: AGPL-3.0. sealctl-core: MIT. Source code: github.com/sealctl/app.") }
            items(blocks) { block ->
                if (block.startsWith("=== ")) {
                    Text(block.removePrefix("=== "), color = Sealctl.colors.ink, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 20.dp, bottom = 4.dp))
                } else {
                    Mono(block, Modifier.padding(vertical = 4.dp), size = 12, color = Sealctl.colors.ink2)
                }
            }
        }
    }
}
