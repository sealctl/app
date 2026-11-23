#!/usr/bin/env python3
"""Tests of scripts/select-tests.py and .github/test-map: example file lists and the suites they
select. Run by supply-chain.yml's `changes` job: python3 scripts/select-tests-test.py"""

import importlib.util
import os
import sys
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("select_tests", os.path.join(HERE, "select-tests.py"))
sel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sel)

PROJ = sel.project()
RULES = sel.load_map()
PACKAGES = ["DesignSystem", "Engine", "Relay", "SealCore", "Vault"]
UI = {"ApprovalTests", "CLIEndToEndTests", "LeaveTests", "OnboardingTests", "PairingTests",
      "PushTests", "SensitiveTests", "SettingsTests", "StagingTests"}


def run(*files, reason=None):
    return sel.select(list(files), PROJ, RULES, reason)


def summary(r):
    return (r["ios"], r["packages"], r["ui"], r["android"])


class Examples(unittest.TestCase):
    def assertFull(self, r):
        self.assertTrue(r["full"], r)
        self.assertEqual(summary(r), (True, PACKAGES, ["all"], True))
        self.assertEqual(r["simulator"], ["EngineTests", "RelayTests", "SealCoreTests", "VaultTests"])

    def test_pr_24_text_buttons(self):
        # app#24: inline text buttons in DesignSystem and three screens
        r = run("SPEC.md", "ios/App/Sources/Main.swift", "ios/App/Sources/Onboarding.swift",
                "ios/App/Sources/Settings.swift",
                "ios/Packages/DesignSystem/Sources/DesignSystem/Components.swift")
        self.assertFalse(r["full"])
        self.assertEqual(summary(r), (True, ["DesignSystem"], ["all"], False))
        self.assertEqual(r["simulator"], [])

    def test_pr_38_deps_and_core_pin(self):
        # app#38: Cargo files (and the sealctl-core pin), Gradle, bindings, workflow
        r = run(".github/workflows/supply-chain.yml", "Cargo.lock", "Cargo.toml",
                "android/core/build.gradle.kts", "android/gradle/libs.versions.toml",
                "ios/Packages/SealCore/Sources/SealCore/sealctl_core.swift", "notices/rust-crates.txt",
                "shared/Cargo.toml", "supply-chain/config.toml", "tools/fake-relay/Cargo.toml")
        self.assertFull(r)

    def test_one_screen(self):
        self.assertEqual(summary(run("ios/App/Sources/Leave.swift")), (True, [], ["LeaveTests"], False))
        self.assertEqual(run("ios/App/Sources/Settings.swift")["ui"],
                         ["ApprovalTests", "LeaveTests", "OnboardingTests", "PairingTests", "SettingsTests"])

    def test_approval_and_app_delegate(self):
        for f in ["ios/App/Sources/Approval.swift", "ios/App/Sources/AppDelegate.swift"]:
            with self.subTest(f):
                ui = run(f)["ui"]
                self.assertIn("ApprovalTests", ui)
                self.assertIn("PushTests", ui)

    def test_screens_every_test_passes_run_every_ui_test(self):
        for f in ["Router.swift", "RootView.swift", "Common.swift", "Main.swift", "Onboarding.swift",
                  "SealctlApp.swift", "Protected.swift"]:
            with self.subTest(f):
                self.assertEqual(run("ios/App/Sources/" + f)["ui"], ["all"])

    def test_test_support_runs_every_ui_test(self):
        for f in ["ios/UITests/SealctlTestCase.swift", "ios/UITests/Support.swift", "ios/scripts/harness.py"]:
            with self.subTest(f):
                self.assertEqual(summary(run(f)), (True, [], ["all"], False))

    def test_one_ui_test_file(self):
        self.assertEqual(summary(run("ios/UITests/PushTests.swift")), (True, [], ["PushTests"], False))

    def test_design_system_and_engine_kit_run_every_ui_test(self):
        r = run("ios/Packages/Engine/Sources/EngineKit/Plans.swift")
        self.assertEqual(summary(r), (True, ["Engine"], ["all"], False))
        r = run("ios/Packages/DesignSystem/Sources/DesignSystem/Tokens.swift")
        self.assertEqual(summary(r), (True, ["DesignSystem"], ["all"], False))

    def test_package_dependents(self):
        r = run("ios/Packages/SealCore/Sources/SealCore/Vectors.swift")
        self.assertEqual(r["packages"], ["Engine", "Relay", "SealCore", "Vault"])
        self.assertEqual(run("ios/Packages/Places/Sources/Places/Places.swift")["packages"], ["Engine"])

    def test_package_tests_only(self):
        r = run("ios/Packages/Vault/Tests/VaultTests/VaultTests.swift")
        self.assertEqual(summary(r), (True, ["Vault"], [], False))
        self.assertEqual(r["simulator"], ["VaultTests"])

    def test_android_only(self):
        r = run("android/app/src/main/java/com/sealctl/app/MainActivity.kt")
        self.assertEqual(summary(r), (False, [], [], True))

    def test_documentation_runs_nothing(self):
        r = run("README.md", "SPEC.md", "brand/mark.svg", "deny.toml", ".github/dependabot.yml")
        self.assertEqual(summary(r), (False, [], [], False))

    def test_everything(self):
        for f in ["Cargo.lock", "Cargo.toml", "shared/src/lib.rs", "shared/Cargo.toml", "rust-toolchain.toml",
                  "tools/fake-relay/src/main.rs", ".github/workflows/ios.yml", ".github/test-map",
                  "scripts/select-tests.py", "uniffi-bindings.toml", "flake.nix"]:
            with self.subTest(f):
                self.assertFull(run(f))

    def test_unmapped_path_runs_everything(self):
        for f in ["ios/App/Sources/NewScreen.swift", "ios/UITests/NewTests.swift", "ios/Widget/W.swift",
                  "new-folder/file"]:
            with self.subTest(f):
                r = run("README.md", f)
                self.assertFull(r)
                self.assertIn("not in .github/test-map", r["reason"])

    def test_not_a_pull_request_runs_everything(self):
        self.assertFull(run(reason="a push run tests everything"))


class Map(unittest.TestCase):
    def test_project(self):
        self.assertEqual(PROJ["ui"], UI)
        self.assertEqual(sorted(p for p, v in PROJ["packages"].items() if v["tests"]), PACKAGES)

    def test_every_ui_class_and_app_source_is_mapped(self):
        named = {s[3:] for _, _, suites in RULES for s in suites if s.startswith("ui:")} - {"all"}
        self.assertEqual(named, UI)
        sources = os.listdir(os.path.join(sel.ROOT, "ios", "App", "Sources"))
        for f in sources:
            with self.subTest(f):
                self.assertFalse(run("ios/App/Sources/" + f)["full"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
