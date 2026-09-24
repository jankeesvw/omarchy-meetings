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
    "meetings_widget_dismiss", str(ROOT / "bin" / "meetings-widget"))
spec = importlib.util.spec_from_loader(loader.name, loader)
widget = importlib.util.module_from_spec(spec)
loader.exec_module(widget)


ROWS = (
    "start_date\tstart_time\tend_date\tend_time\ttitle\tcalendar\n"
    "2026-09-02\t09:00\t2026-09-02\t09:30\tStandup\tWork\n"
    "2026-09-02\t12:00\t2026-09-02\t13:00\tLunch\tWork\n"
)


def rows_for(day):
    with mock.patch.object(widget, "run_capped", return_value=ROWS):
        return widget.parse_google_rows(day, day)


class DismissTests(unittest.TestCase):
    def test_a_dismissed_occurrence_leaves_the_day(self):
        day = date(2026, 9, 2)
        rows = rows_for(day)
        standup = next(row for row in rows if row["title"] == "Standup")

        with mock.patch.object(widget, "DISMISSED", {widget.dismiss_key(standup, day): "2026-09-02"}):
            titles = [event["title"] for event in widget.build_day(rows, day)["events"]]

        self.assertEqual(titles, ["Lunch"])

    def test_the_same_meeting_on_another_day_is_untouched(self):
        """The key carries the date, so hiding one occurrence of a repeat says
        nothing about next week's."""
        hidden_day = date(2026, 9, 2)
        other_day = date(2026, 9, 9)
        standup = next(row for row in rows_for(hidden_day) if row["title"] == "Standup")
        key = widget.dismiss_key(standup, hidden_day)

        rows = rows_for(other_day)
        for row in rows:
            row["start_date"] = row["end_date"] = other_day.isoformat()

        with mock.patch.object(widget, "DISMISSED", {key: "2026-09-02"}):
            titles = [event["title"] for event in widget.build_day(rows, other_day)["events"]]

        self.assertIn("Standup", titles)

    def test_a_row_without_an_id_still_gets_a_stable_key(self):
        """gcalcli hands back no id at all for some rows, and two keys that
        collide would hide an appointment nobody dismissed."""
        day = date(2026, 9, 2)
        rows = rows_for(day)
        first, second = rows[0], rows[1]

        self.assertNotEqual(widget.dismiss_key(first, day), widget.dismiss_key(second, day))
        self.assertEqual(widget.dismiss_key(first, day), widget.dismiss_key(first, day))

    def test_the_key_starts_with_the_day_it_falls_on(self):
        """The dismiss command reads that first field to decide what is old
        enough to sweep up, so the shape is part of the contract."""
        day = date(2026, 9, 2)
        key = widget.dismiss_key(rows_for(day)[0], day)

        self.assertTrue(key.startswith("2026-09-02|"))


if __name__ == "__main__":
    unittest.main()
