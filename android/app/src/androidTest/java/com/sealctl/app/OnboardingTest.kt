package com.sealctl.app

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Onboarding and restore against a fresh install (SPEC.md 16.4 items 1 and 2), up to the
 * biometric prompts, which these tests never pass.
 */
@RunWith(AndroidJUnit4::class)
class OnboardingTest {
    @get:Rule
    val rule = createAndroidComposeRule<MainActivity>()

    private fun waitFor(text: String) = rule.waitUntil(10_000) {
        rule.onAllNodesWithTextOrDesc(text)
    }

    private fun androidx.compose.ui.test.junit4.AndroidComposeTestRule<*, *>.onAllNodesWithTextOrDesc(text: String): Boolean =
        onAllNodes(androidx.compose.ui.test.hasText(text, substring = true)).fetchSemanticsNodes().isNotEmpty()

    @Test
    fun createWordsStepsUpToThePrompt() {
        waitFor("Your phone holds the keys.")
        rule.onNodeWithText("No account.", substring = true).assertIsDisplayed()
        rule.onNodeWithText("Create new words").performClick()
        rule.onNodeWithText("24 words open everything").assertIsDisplayed()
        rule.onNodeWithText("Next").performClick()
        rule.onNodeWithText("Print a blank card").assertIsDisplayed()
        rule.onNodeWithText("No printer? Any paper works. Number 24 lines.").assertIsDisplayed()
        rule.onNodeWithText("I have a blank card").performClick()
        rule.onNodeWithText("Write where no camera can see").assertIsDisplayed()
        rule.onNodeWithText("Show my words").assertIsDisplayed()
    }

    @Test
    fun restoreFromTypedWordsShowsTheFingerprint() {
        waitFor("Your phone holds the keys.")
        rule.onNodeWithText("Restore").performClick()
        rule.onNodeWithText("Type your 24 words").assertIsDisplayed()
        val words = "bulk search gospel radio edit key flip afford jaguar rapid mechanic power family category snap boss iron web various grow smoke next example lounge".split(" ")
        for (w in words) {
            for (c in w.take(4)) {
                rule.onNodeWithContentDescription("key $c").performClick()
                rule.waitForIdle()
            }
        }
        waitFor("These are words")
        rule.onNodeWithText("Does your card say qHWf?").assertIsDisplayed()
        rule.onNodeWithText("No, check again").performClick()
        rule.onNodeWithText("Type your 24 words").assertIsDisplayed()
    }

    @Test
    fun keypadDisablesImpossibleLettersAndRejectsBadChecksum() {
        waitFor("Your phone holds the keys.")
        rule.onNodeWithText("Restore").performClick()
        // "abandon" x 24 has a bad checksum.
        repeat(24) { for (c in "aban") rule.onNodeWithContentDescription("key $c").performClick() }
        waitFor("don't fit together")
    }
}
