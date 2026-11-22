package com.sealctl.vault

import android.content.Context
import android.os.Build
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.sealctl.core.app.Biometrics
import javax.crypto.Cipher
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/** The outcome of one prompt. */
sealed class AuthResult {
    data class Success(val cipher: Cipher?) : AuthResult()
    data object Cancelled : AuthResult()
    data object LockedOut : AuthResult()
    data class Failed(val code: Int, val message: String) : AuthResult()
}

/** BiometricPrompt, one prompt per confirmation (SPEC.md 9.6, 11.3 step 4). */
object Biometric {
    /** Strong biometrics on this phone, for `decide`. */
    fun availability(context: Context): Biometrics =
        when (BiometricManager.from(context).canAuthenticate(BIOMETRIC_STRONG)) {
            BiometricManager.BIOMETRIC_SUCCESS -> Biometrics.AVAILABLE
            else -> Biometrics.UNAVAILABLE
        }

    /**
     * Levels 2 and 3: strong biometrics only, no device credential, confirmation required,
     * negative button "Cancel", with a CryptoObject on the gate key.
     */
    suspend fun strong(activity: FragmentActivity, title: String, cancel: String, cipher: Cipher): AuthResult {
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .setConfirmationRequired(true)
            .setNegativeButtonText(cancel)
            .build()
        return prompt(activity, info, BiometricPrompt.CryptoObject(cipher))
    }

    /**
     * Showing the words during onboarding: strong biometrics or the screen lock, with a
     * CryptoObject on the words key. Before API 30 the words key accepts biometrics only.
     */
    suspend fun words(activity: FragmentActivity, title: String, subtitle: String, cancel: String, cipher: Cipher): AuthResult {
        val b = BiometricPrompt.PromptInfo.Builder().setTitle(title).setSubtitle(subtitle)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            b.setAllowedAuthenticators(BIOMETRIC_STRONG or DEVICE_CREDENTIAL)
        } else {
            b.setAllowedAuthenticators(BIOMETRIC_STRONG).setNegativeButtonText(cancel)
        }
        return prompt(activity, b.build(), BiometricPrompt.CryptoObject(cipher))
    }

    private suspend fun prompt(
        activity: FragmentActivity,
        info: BiometricPrompt.PromptInfo,
        crypto: BiometricPrompt.CryptoObject,
    ): AuthResult = suspendCancellableCoroutine { cont ->
        val prompt = BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    if (cont.isActive) cont.resume(AuthResult.Success(result.cryptoObject?.cipher))
                }

                override fun onAuthenticationError(code: Int, msg: CharSequence) {
                    if (!cont.isActive) return
                    cont.resume(
                        when (code) {
                            BiometricPrompt.ERROR_LOCKOUT, BiometricPrompt.ERROR_LOCKOUT_PERMANENT -> AuthResult.LockedOut
                            BiometricPrompt.ERROR_NEGATIVE_BUTTON, BiometricPrompt.ERROR_USER_CANCELED,
                            BiometricPrompt.ERROR_CANCELED -> AuthResult.Cancelled
                            else -> AuthResult.Failed(code, msg.toString())
                        },
                    )
                }
            },
        )
        prompt.authenticate(info, crypto)
        cont.invokeOnCancellation { prompt.cancelAuthentication() }
    }
}
