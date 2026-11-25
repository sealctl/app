package com.sealctl.designsystem

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** The brand tokens (dot-github/brand/tokens.css, SPEC.md 11.1). */
@Immutable
data class SealctlColors(
    val paper: Color,
    val surface: Color,
    val surface2: Color,
    val ink: Color,
    val ink2: Color,
    val muted: Color,
    val border: Color,
    val accent: Color,
    val accentSoft: Color,
    val onAccent: Color,
    val open: Color,
    val waiting: Color,
    /**
     * The Activity heatmap (SPEC.md 11.12): no use, then four steps from the soft accent to
     * the accent, each step clear of the last and the first clear of the card.
     */
    val heat: List<Color>,
)

val LightColors = SealctlColors(
    paper = Color(0xFFFFFFFF),
    surface = Color(0xFFF6F7F9),
    surface2 = Color(0xFFEEF0F4),
    ink = Color(0xFF1A2133),
    ink2 = Color(0xFF3E4659),
    muted = Color(0xFF5F6677),
    border = Color(0xFFE3E6EC),
    accent = Color(0xFFB4232C),
    accentSoft = Color(0xFFF8E3E5),
    onAccent = Color(0xFFFFFFFF),
    open = Color(0xFF157F3C),
    waiting = Color(0xFFB45309),
    heat = listOf(Color(0xFFE3E6EC), Color(0xFFDD969B), Color(0xFFCF7076), Color(0xFFC24951), Color(0xFFB4232C)),
)

val DarkColors = SealctlColors(
    paper = Color(0xFF0E121A),
    surface = Color(0xFF151A24),
    surface2 = Color(0xFF1B2130),
    ink = Color(0xFFEEF0F5),
    ink2 = Color(0xFFC8CDD9),
    muted = Color(0xFF949BAD),
    border = Color(0xFF242B3A),
    accent = Color(0xFFFF5C63),
    accentSoft = Color(0xFF3B2327),
    onAccent = Color(0xFF12151C),
    open = Color(0xFF4CC47C),
    waiting = Color(0xFFF0A54A),
    heat = listOf(Color(0xFF242B3A), Color(0xFF893A3F), Color(0xFFB1454B), Color(0xFFD85157), Color(0xFFFF5C63)),
)

val LocalSealctlColors = staticCompositionLocalOf { LightColors }

/** Monospace for machine names, keys, commands, paths, tags, fingerprints and the wordmark. */
val Mono = FontFamily.Monospace

object Sealctl {
    val colors: SealctlColors
        @Composable get() = LocalSealctlColors.current
}

private val typography = Typography().let { t ->
    t.copy(
        headlineSmall = t.headlineSmall.copy(fontWeight = FontWeight.SemiBold),
        titleLarge = t.titleLarge.copy(fontWeight = FontWeight.SemiBold),
    )
}

/** Monospace text style at a size. */
fun monoStyle(size: Int = 15, weight: FontWeight = FontWeight.Normal) =
    TextStyle(fontFamily = Mono, fontSize = size.sp, fontWeight = weight)

@Composable
fun SealctlTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val c = if (dark) DarkColors else LightColors
    val scheme = if (dark) {
        darkColorScheme(
            primary = c.accent, onPrimary = c.onAccent, background = c.paper, onBackground = c.ink,
            surface = c.surface, onSurface = c.ink, surfaceVariant = c.surface2, onSurfaceVariant = c.muted,
            outline = c.border, secondary = c.ink2, onSecondary = c.paper, error = c.accent,
            surfaceContainer = c.surface, surfaceContainerLow = c.surface, surfaceContainerHigh = c.surface2,
            primaryContainer = c.accentSoft, onPrimaryContainer = c.ink,
        )
    } else {
        lightColorScheme(
            primary = c.accent, onPrimary = c.onAccent, background = c.paper, onBackground = c.ink,
            surface = c.surface, onSurface = c.ink, surfaceVariant = c.surface2, onSurfaceVariant = c.muted,
            outline = c.border, secondary = c.ink2, onSecondary = c.paper, error = c.accent,
            surfaceContainer = c.surface, surfaceContainerLow = c.surface, surfaceContainerHigh = c.surface2,
            primaryContainer = c.accentSoft, onPrimaryContainer = c.ink,
        )
    }
    CompositionLocalProvider(LocalSealctlColors provides c) {
        MaterialTheme(colorScheme = scheme, typography = typography, content = content)
    }
}
