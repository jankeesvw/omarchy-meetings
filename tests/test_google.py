import importlib.machinery
import importlib.util
import os
import unittest
from datetime import date
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
os.environ["MEETINGS_CONFIG"] = str(ROOT / "tests" / "missing-config.json")

loader = importlib.machinery.SourceFileLoader(
    "meetings_widget_google", str(ROOT / "bin" / "meetings-widget"))
spec = importlib.util.spec_from_loader(loader.name, loader)
widget = importlib.util.module_from_spec(spec)
loader.exec_module(widget)


class GoogleCalendarTests(unittest.TestCase):
    def test_carriage_returns_inside_description_do_not_drop_event(self):
        output = (
            "start_date\tstart_time\tend_date\tend_time\ttitle\tdescription\tcalendar\n"
            "2026-09-02\t12:00\t2026-09-02\t13:00\t"
            "Partner sync\t"
            "Microsoft Teams meeting\r\\nJoin: https://teams.microsoft.com/example\t"
            "Work\n"
        )

        with mock.patch.object(widget, "run_capped", return_value=output):
            rows = widget.parse_google_rows(date(2026, 9, 2), date(2026, 9, 2))

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["calendar"], "Work")
        self.assertEqual(rows[0]["title"], "Partner sync")
        self.assertEqual(
            rows[0]["description"],
            "Microsoft Teams meeting\r\\nJoin: https://teams.microsoft.com/example",
        )
        day = widget.build_day(rows, date(2026, 9, 2))
        self.assertEqual(
            [event["title"] for event in day["events"]],
            ["Partner sync"],
        )

    def test_crlf_record_endings_are_accepted(self):
        output = (
            "start_date\tstart_time\tend_date\tend_time\ttitle\tcalendar\r\n"
            "2026-09-02\t12:00\t2026-09-02\t13:00\tReview\tWork\r\n"
        )

        with mock.patch.object(widget, "run_capped", return_value=output):
            rows = widget.parse_google_rows(date(2026, 9, 2), date(2026, 9, 2))

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["calendar"], "Work")

    def test_lf_records_preserve_carriage_return_in_final_field(self):
        output = (
            "start_date\tstart_time\tend_date\tend_time\ttitle\tcalendar\tdescription\n"
            "2026-09-02\t12:00\t2026-09-02\t13:00\tReview\tWork\tNotes\r\n"
        )

        with mock.patch.object(widget, "run_capped", return_value=output):
            rows = widget.parse_google_rows(date(2026, 9, 2), date(2026, 9, 2))

        self.assertEqual(rows[0]["description"], "Notes\r")


if __name__ == "__main__":
    unittest.main()
