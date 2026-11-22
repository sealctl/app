import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

/// Text components apply Markdown only for code spans (Components.swift).
struct MarkdownTests {
    @Test func codeSpansInTheAppsCopyAreDrawn() throws {
        let a = try #require(Text.codeSpansOnly("Run `sealctl unseal --all` on each computer."))
        #expect(String(a.characters) == "Run sealctl unseal --all on each computer.")
        #expect(a.runs.contains { $0.inlinePresentationIntent == .code })
    }

    @Test func textWithoutBackticksIsDrawnAsItIs() {
        #expect(Text.codeSpansOnly("Allow once for dev@mbp.example.com?") == nil)
        #expect(Text.codeSpansOnly("a*b*c") == nil)
    }

    @Test func linksEmphasisAndEntitiesAreNotApplied() {
        // A machine's name or repository next to the app's own code spans.
        #expect(Text.codeSpansOnly("First use in [legit-repo](<x evil-repo>). Run `sealctl status`.") == nil)
        #expect(Text.codeSpansOnly("Run `sealctl pair` on <https://phish.example>") == nil)
        #expect(Text.codeSpansOnly("Run `x` on a*b*c") == nil)
        #expect(Text.codeSpansOnly("Run `x` on a&amp;b") == nil)
        #expect(Text.codeSpansOnly("Run `x` on a\\_b") == nil)
        #expect(Text.codeSpansOnly("Run `x` on https://phish.example/a") == nil)
    }
}
