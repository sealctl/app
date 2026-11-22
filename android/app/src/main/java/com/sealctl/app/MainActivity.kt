package com.sealctl.app

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.ui.Modifier
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import com.sealctl.designsystem.Sealctl
import com.sealctl.designsystem.SealctlTheme
import com.sealctl.ui.MainScreen
import com.sealctl.ui.NeedsScreenLockScreen
import com.sealctl.ui.OnboardingFlow
import com.sealctl.ui.WordsLostScreen
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.getAndUpdate
import kotlinx.coroutines.launch

/** Screens pushed over the tabs. */
sealed class Route {
    data class MachineDetail(val key: String) : Route()
    data class LostMachine(val key: String) : Route()
    data class Pair(val code: String? = null, val fromLink: Boolean = false) : Route()
    data object Answers : Route()
    data object Places : Route()
    data object Devices : Route()
    data object About : Route()
    data object Licences : Route()
    data object ShowWords : Route()
    data object DeleteRelay : Route()
    data object Erase : Route()
    data object Leave : Route()
    data class Report(val id: String) : Route()
    data class Delayed(val id: String) : Route()
    data class Sensitive(val requestId: String) : Route()
    data class Activity(val machine: String? = null) : Route()
    data class Inventory(val machine: String? = null) : Route()
}

/** UI state shared by the screens: the route stack, protected screens. */
object Ui {
    val stack = mutableStateListOf<Route>()
    val tab = androidx.compose.runtime.mutableIntStateOf(0)
    /** A screen showing the words is up: FLAG_SECURE (SPEC.md 11.21). */
    val secure = MutableStateFlow(0)
    /** The request the card should show first (from a notification tap). */
    val focusRequest = MutableStateFlow<String?>(null)
    /** A line above Welcome after leaving. */
    val goodbye = MutableStateFlow(false)

    /** What a notification tap asks to show; set only by [OpenActivity], which is not exported. */
    data class Open(val requestId: String?, val screen: String?)
    val opening = MutableStateFlow<Open?>(null)

    fun push(r: Route) { stack.add(r) }
    fun pop() { if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex) }
    fun reset() = stack.clear()
    fun toast(text: String) = Graph.engine.toast(text)
}

class MainActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handle(intent)
        lifecycleScope.launch {
            combine(Ui.secure, Graph.words.shown) { n, words -> n > 0 || words != null }.collect { secure ->
                if (secure) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) setRecentsScreenshotEnabled(!secure)
            }
        }
        setContent { SealctlTheme { Root(this) } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /**
     * This activity is exported (the launcher, the pairing link), so its extras can come from
     * any app and are never read (SPEC.md 10.2). A notification tap arrives through
     * [OpenActivity], which leaves what to show in [Ui.opening]; a link only opens the scanner.
     */
    private fun handle(intent: Intent?) {
        val open = Ui.opening.getAndUpdate { null }
        open?.requestId?.let { id ->
            Ui.focusRequest.value = id
            lifecycleScope.launch {
                val e = Graph.engine
                if (e.waiting.value.none { it.relay.id == id }) e.catchUp()
                val w = e.waiting.value.firstOrNull { it.relay.id == id }
                if (w != null && w.verdict.asking == com.sealctl.core.app.Asking.IN_APP) Ui.push(Route.Sensitive(id))
            }
        }
        open?.screen?.let { s ->
            when {
                s.startsWith("report:") -> Ui.push(Route.Report(s.removePrefix("report:")))
                s.startsWith("delayed:") -> Ui.push(Route.Delayed(s.removePrefix("delayed:")))
            }
        }
        val link = intent?.takeIf { it.action == Intent.ACTION_VIEW }?.data
        if (link != null && link.scheme == "https" && link.host == "sealctl.com" && link.path == "/p") {
            // A link opened outside the app leads to the scanner (SPEC.md 11.5).
            Ui.push(Route.Pair(code = null, fromLink = true))
        }
    }
}

@Composable
private fun Root(activity: MainActivity) {
    val phase by Graph.engine.phase.collectAsState()
    Box(Modifier.fillMaxSize().background(Sealctl.colors.paper)) {
        when (val p = phase) {
            Phase.Loading -> {}
            Phase.NeedsScreenLock -> NeedsScreenLockScreen()
            is Phase.WordsLost -> WordsLostScreen(activity, p.invalidated)
            Phase.Ready -> {
                BackHandler(enabled = Ui.stack.isNotEmpty()) { Ui.pop() }
                MainScreen(activity)
            }
            else -> OnboardingFlow(activity, p)
        }
    }
}
