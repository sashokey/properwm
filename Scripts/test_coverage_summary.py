import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


class CoverageSummaryTests(unittest.TestCase):
    def invoke(self, report):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "coverage.json"
            path.write_text(json.dumps(report))
            return subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name("coverage_summary.py")), str(path)],
                                  capture_output=True, text=True)

    def report(self):
        return {"coveredLines": 990, "executableLines": 1000, "lineCoverage": 0.99, "targets": [
            {"name": "ProperWMTests.xctest", "coveredLines": 900, "executableLines": 900, "lineCoverage": 1.0},
            {"name": "ProperWM.app", "coveredLines": 90, "executableLines": 100, "lineCoverage": 0.9}]}

    def test_reports_only_application_lines_even_when_tests_raise_total(self):
        result = self.invoke(self.report())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("90.00%", result.stdout)
        self.assertIn("90/100", result.stdout)
        self.assertIn("ProperWM.app", result.stdout)
        self.assertNotIn("99.00%", result.stdout)

    def test_target_order_does_not_change_the_selected_application(self):
        report = self.report()
        report["targets"].reverse()
        result = self.invoke(report)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("90.00%", result.stdout)

    def test_missing_or_duplicate_application_target_fails(self):
        for targets in [[], [self.report()["targets"][0]], [self.report()["targets"][1]] * 2]:
            with self.subTest(targets=targets):
                report = self.report()
                report["targets"] = targets
                result = self.invoke(report)
                self.assertNotEqual(result.returncode, 0)

    def test_invalid_or_empty_application_counts_fail(self):
        for covered, executable in [(2, 1), (-1, 100), (0, 0), (True, 100), (1.5, 100)]:
            with self.subTest(covered=covered, executable=executable):
                report = self.report()
                report["targets"][1].update(coveredLines=covered, executableLines=executable)
                self.assertNotEqual(self.invoke(report).returncode, 0)


if __name__ == "__main__":
    unittest.main()
