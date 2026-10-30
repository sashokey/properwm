import pathlib
import tempfile
import unittest

from select_xcode import newest_stable_xcode


class SelectXcodeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.apps = pathlib.Path(self.directory.name).resolve()

    def app(self, name):
        path = self.apps / name
        path.mkdir()
        return path

    def test_selects_newest_stable_version_numerically(self):
        self.app("Xcode_27.9.app")
        expected = self.app("Xcode_27.10.app")
        self.app("Xcode_27.2.app")
        self.assertEqual(newest_stable_xcode(self.apps), expected)

    def test_rejects_beta_and_release_candidate_aliases(self):
        expected = self.app("Xcode_27.1.app")
        beta = self.app("Xcode_28_beta_1.app")
        candidate = self.app("Xcode_27.2_Release_Candidate.app")
        (self.apps / "Xcode_28.app").symlink_to(beta, target_is_directory=True)
        (self.apps / "Xcode_27.2.app").symlink_to(candidate, target_is_directory=True)
        self.assertEqual(newest_stable_xcode(self.apps), expected)

    def test_resolves_default_alias_without_selecting_it_over_newer_release(self):
        older = self.app("Xcode_27.app")
        expected = self.app("Xcode_27.1.app")
        (self.apps / "Xcode.app").symlink_to(older, target_is_directory=True)
        self.assertEqual(newest_stable_xcode(self.apps), expected)

    def test_accepts_a_future_stable_major(self):
        self.app("Xcode_27.1.app")
        expected = self.app("Xcode_28.app")
        self.assertEqual(newest_stable_xcode(self.apps), expected)

    def test_fails_instead_of_falling_back_to_xcode_26(self):
        self.app("Xcode_26.6.app")
        with self.assertRaisesRegex(ValueError, "No stable Xcode 27"):
            newest_stable_xcode(self.apps)

    def test_ignores_files_and_broken_aliases(self):
        (self.apps / "Xcode_28.app").touch()
        (self.apps / "Xcode_29.app").symlink_to(self.apps / "missing")
        with self.assertRaises(ValueError):
            newest_stable_xcode(self.apps)


if __name__ == "__main__":
    unittest.main()
