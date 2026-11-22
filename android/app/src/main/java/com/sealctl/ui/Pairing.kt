package com.sealctl.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.sealctl.app.Graph
import com.sealctl.app.MainActivity
import com.sealctl.app.Route
import com.sealctl.app.Texts
import com.sealctl.app.Ui
import com.sealctl.core.PairingOffer
import com.sealctl.core.app.Machine
import com.sealctl.designsystem.Body
import com.sealctl.designsystem.Mono
import com.sealctl.designsystem.Muted
import com.sealctl.designsystem.PlainButton
import com.sealctl.designsystem.PrimaryButton
import com.sealctl.designsystem.SecondaryButton
import com.sealctl.designsystem.Sealctl
import com.sealctl.designsystem.Title
import com.sealctl.vault.Biometric
import java.util.concurrent.Executors
import kotlinx.coroutines.launch
import zxingcpp.BarcodeReader

private sealed class PairStep {
    data object Scan : PairStep()
    data object Type : PairStep()
    data class Confirm(val offer: PairingOffer) : PairStep()
    data class Duplicate(val offer: PairingOffer, val existing: Machine) : PairStep()
    data class CardWords(val offer: PairingOffer, val replaces: String?) : PairStep()
    data class Done(val name: String) : PairStep()
}

/** Pairing (SPEC.md 11.5, 11.6): scan, or type the code; confirm; biometrics; register. */
@Composable
fun PairingScreen(activity: MainActivity, route: Route.Pair) {
    val engine = Graph.engine
    var step by remember { mutableStateOf<PairStep>(PairStep.Scan) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    fun accept(text: String) {
        engine.parseOffer(text).fold(
            onSuccess = { offer ->
                error = null
                val same = engine.liveMachines().firstOrNull { it.name == offer.name() && it.key != offer.machineKey() }
                step = if (same != null) PairStep.Duplicate(offer, same) else PairStep.Confirm(offer)
            },
            onFailure = { error = it.message },
        )
    }

    suspend fun register(offer: PairingOffer, replaces: String?) {
        val r = engine.pair(offer, replaces)
        r.fold(onSuccess = { step = PairStep.Done(engine.displayName(it)) }, onFailure = { error = it.message })
    }

    suspend fun confirm(offer: PairingOffer, replaces: String?) {
        if (Biometric.availability(activity) != com.sealctl.core.app.Biometrics.AVAILABLE) {
            step = PairStep.CardWords(offer, replaces); return
        }
        when (val g = biometricGate(activity, "Confirm pairing ${offer.name()}.")) {
            GateResult.Passed -> register(offer, replaces)
            GateResult.Cancelled -> {}
            GateResult.Changed, GateResult.LockedOut -> step = PairStep.CardWords(offer, replaces)
            is GateResult.Failed -> error = g.message
        }
    }

    when (val s = step) {
        PairStep.Scan -> ScanStep(fromLink = route.fromLink, error = error, onCode = ::accept, onType = { error = null; step = PairStep.Type })
        PairStep.Type -> TypeStep(error, onCode = ::accept, onBack = { error = null; step = PairStep.Scan })
        is PairStep.Confirm -> Page(null, bottom = {
            ErrorText(error)
            PrimaryButton("Pair", { scope.launch { confirm(s.offer, null) } })
            PlainButton("Cancel", { Ui.pop() })
        }) {
            Gap(24)
            Title("Pair this machine?")
            Mono(s.offer.name(), size = 18, weight = FontWeight.SemiBold)
            Row3(s.offer)
            Body("It will be able to ask this phone for keys. You still approve every request.")
        }
        is PairStep.Duplicate -> {
            val sameHint = s.offer.hint() != null && s.offer.hint() == s.existing.hint
            Page(null, bottom = {
                ErrorText(error)
                if (sameHint) {
                    PrimaryButton("Replace", { scope.launch { confirm(s.offer, s.existing.key) } })
                    SecondaryButton("Pair as new", { scope.launch { confirm(s.offer, null) } })
                } else {
                    PrimaryButton("Yes, replace it", { scope.launch { confirm(s.offer, s.existing.key) } })
                    SecondaryButton("No, another machine", { scope.launch { confirm(s.offer, null) } })
                }
                PlainButton("Cancel", { Ui.pop() })
            }) {
                Gap(24)
                if (sameHint) {
                    Title("Already paired")
                    Body("${s.offer.name()} is already paired (same hardware, last seen ${Texts.ago(s.existing.lastSeen?.toLong())}). Replace it?")
                } else {
                    Title("Same machine?")
                    Body("Another machine is already called ${s.offer.name()} (${s.existing.model ?: s.existing.os}, paired ${Texts.isoDate(s.existing.pairedAt.toLong())}). Same machine?")
                }
            }
        }
        is PairStep.CardWords -> CardWords(activity, 2, 2, "Use your card", onPassed = {
            engine.vault.resetGate()
            scope.launch { register(s.offer, s.replaces) }
        }, onCancel = { step = PairStep.Confirm(s.offer) })
        is PairStep.Done -> Page(null, bottom = { PrimaryButton("Done", { Ui.pop() }) }) {
            Gap(24)
            Title(Texts.paired(s.name))
        }
    }
}

@Composable
private fun Row3(offer: PairingOffer) {
    val parts = listOfNotNull(offer.os().ifEmpty { null }, offer.model())
    androidx.compose.foundation.layout.Row {
        Muted(parts.joinToString(" · ") + if (parts.isNotEmpty()) " · " else "")
        Mono("#${offer.tag()}", size = 14, color = Sealctl.colors.muted)
    }
}

@Composable
private fun ScanStep(fromLink: Boolean, error: String?, onCode: (String) -> Unit, onType: () -> Unit) {
    val context = ctx()
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var denied by remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it; denied = !it }
    Page("Scan the code", bottom = {
        ErrorText(error)
        SecondaryButton("Can't scan? Type the pairing code", onType)
    }) {
        if (fromLink) Body("Scan the code with sealctl. On a computer without a terminal, open the link in its browser to see the code.")
        Body("Run `sealctl pair` on your computer and point the camera at the code.")
        if (granted) {
            Camera(onCode)
        } else if (denied) {
            Body("The camera is needed to scan the pairing code. Allow it in Settings.")
            PrimaryButton("Open settings", { openAppSettings(context) })
        } else {
            Muted("The camera scans the pairing code that sealctl pair shows on your computer.")
            PrimaryButton("Allow camera", { launcher.launch(Manifest.permission.CAMERA) })
        }
    }
}

/** CameraX preview with zxing-cpp decoding on the phone; nothing leaves the device. */
@Composable
private fun Camera(onCode: (String) -> Unit) {
    val context = ctx()
    val owner = LocalLifecycleOwner.current
    var last by remember { mutableStateOf<String?>(null) }
    val executor = remember { Executors.newSingleThreadExecutor() }
    DisposableEffect(Unit) { onDispose { executor.shutdown() } }
    Box(
        Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(12.dp))
            .border(BorderStroke(3.dp, Sealctl.colors.accent), RoundedCornerShape(12.dp))
            .semantics { contentDescription = "Camera" },
        contentAlignment = Alignment.Center,
    ) {
        AndroidView(factory = { ctx ->
            val view = PreviewView(ctx)
            val providerFuture = ProcessCameraProvider.getInstance(ctx)
            providerFuture.addListener({
                val provider = providerFuture.get()
                val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                val reader = BarcodeReader().apply { options.formats = setOf(BarcodeReader.Format.QR_CODE) }
                val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                analysis.setAnalyzer(executor) { image ->
                    val text = runCatching { reader.read(image).firstOrNull()?.text }.getOrNull()
                    image.close()
                    if (text != null && text != last) {
                        last = text
                        ContextCompat.getMainExecutor(context).execute { onCode(text) }
                    }
                }
                runCatching {
                    provider.unbindAll()
                    provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                }
            }, ContextCompat.getMainExecutor(ctx))
            view
        }, modifier = Modifier.fillMaxSize())
    }
}

@Composable
private fun TypeStep(error: String?, onCode: (String) -> Unit, onBack: () -> Unit) {
    var text by remember { mutableStateOf("") }
    Page("Type the pairing code", onBack = onBack, bottom = {
        ErrorText(error)
        PrimaryButton("Continue", { onCode(text) }, enabled = text.isNotBlank())
    }) {
        Body("`sealctl pair` prints the code under the QR code. Type or paste it here.")
        OutlinedTextField(
            value = text, onValueChange = { text = it.trim() },
            modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp).semantics { contentDescription = "Pairing code" },
            label = { Text("Pairing code") }, minLines = 3,
        )
    }
}
