import copy
import importlib.machinery
import importlib.util
import io
import json
import os
import sys
import unittest
from contextlib import redirect_stdout
from datetime import date
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader(
    "meetings_widget_formats", str(ROOT / "bin" / "meetings-widget"))
spec = importlib.util.spec_from_loader(loader.name, loader)
widget = importlib.util.module_from_spec(spec)
with mock.patch.dict(os.environ, {"MEETINGS_CONFIG": str(ROOT / "tests" / "missing-config.json")}):
    loader.exec_module(widget)

DAY = date(2026, 9, 2)
# gcalcli's --details all --json schema, not the flat TSV column layout.
EVENT = {
    "id": "event-a",
    "time": {"start_date": "2026-09-02", "start_time": "12:00",
             "end_date": "2026-09-02", "end_time": "13:00"},
    "title": "Partner sync",
    "location": "Room A",
    "description": "Agenda",
    "calendar": "Work",
    "email": "organizer@example.com",
    "url": {"html_link": "https://calendar.google.com/calendar/event?eid=example",
            "hangout_link": ""},
    "conference": [{"conference_entry_point_type": "video",
                    "conference_uri": "https://teams.microsoft.com/l/meetup-join/example"}],
    "attendees": [{"attendee_email": "guest@example.com",
                   "attendee_response_status": "accepted"}],
}


class GoogleFormatTests(unittest.TestCase):
    def setUp(self):
        for name, value in {"_google_json_support": None, "GOOGLE_ERROR": "",
                            "VISIBLE": None, "ONLY_CALENDAR": None,
                            "SKIP_CALENDARS": [], "SKIP_TITLES": []}.items():
            patch = mock.patch.object(widget, name, value)
            patch.start()
            self.addCleanup(patch.stop)

    def parse_json(self, payload):
        with mock.patch.object(widget, "_google_json_support", True), \
                mock.patch.object(widget, "run_capped", return_value=json.dumps(payload)):
            return widget.parse_google_rows(DAY, DAY)

    def test_json_preserves_text_boundaries_and_the_following_event(self):
        first = copy.deepcopy(EVENT)
        first.update(title="Partner\tsync", location="Room\tA",
                     description="Before\tAfter\r\nNext\u2028line\\nLiteral",
                     calendar="Work\tTeam")
        second = copy.deepcopy(EVENT)
        second.update(id="event-b", title="Second meeting", calendar="Personal")
        with mock.patch.object(widget, "VISIBLE", ["Work\tTeam", "Personal"]):
            rows = self.parse_json([first, second])
            events = widget.build_day(rows, DAY)["events"]
        self.assertEqual(len(events), 2)
        for key in ("id", "title", "location", "description", "calendar"):
            self.assertEqual(events[0][key], first[key])
        self.assertEqual(events[0]["hangout"], first["conference"][0]["conference_uri"])
        self.assertEqual(events[0]["link"], first["url"]["html_link"])
        self.assertFalse(events[0]["attendees_embedded"])
        self.assertEqual(events[1]["title"], "Second meeting")

    def test_json_maps_all_day_and_missing_optional_details(self):
        event = {"title": "Holiday", "calendar": "Work", "time": {
            "start_date": "2026-09-02", "start_time": "",
            "end_date": "2026-09-03", "end_time": ""}}
        rows = self.parse_json([event])
        day = widget.build_day(rows, DAY)
        self.assertEqual(day["events"], [])
        self.assertEqual(day["allday"][0]["title"], "Holiday")
        self.assertEqual(rows[0]["conference_uri"], "")

    def test_json_empty_agenda_is_success(self):
        self.assertEqual(self.parse_json([]), [])
        self.assertEqual(widget.GOOGLE_ERROR, "")

    def test_invalid_json_shapes_do_not_become_partial_agendas(self):
        for broken in (None, {}, "text", [None], [EVENT, {}],
                       [dict(EVENT, title="")],
                       [{key: value for key, value in EVENT.items() if key != "calendar"}],
                       [dict(EVENT, time=[])], [dict(EVENT, title=[])],
                       [dict(EVENT, conference=[None])], [dict(EVENT, url=[])],
                       [dict(EVENT, time=dict(EVENT["time"], start_time=None))]):
            with self.subTest(broken=broken):
                self.assertIsNone(self.parse_json(broken))
                self.assertEqual(widget.GOOGLE_ERROR, "google-invalid-data")

    def test_json_failure_does_not_retry_as_tsv(self):
        for output in (None, "", "[", '{"error":"failed"}'):
            with self.subTest(output=output), \
                    mock.patch.object(widget, "_google_json_support", True), \
                    mock.patch.object(widget, "run_capped", return_value=output) as run:
                self.assertIsNone(widget.parse_google_rows(DAY, DAY))
                run.assert_called_once()
                self.assertIn("--json", run.call_args.args[0])

    def test_cli_probe_is_cached_and_range_and_decline_filter_survive(self):
        with mock.patch.object(widget, "run_capped", side_effect=[
                "usage: gcalcli agenda [--json]\n  --json  JSON output\n", "[]", "[]"]) as run:
            self.assertEqual(widget.parse_google_rows(DAY, DAY), [])
            self.assertEqual(widget.parse_google_rows(DAY, DAY), [])
        self.assertEqual(run.call_count, 3)
        self.assertEqual(run.call_args_list[0], mock.call(
            ["gcalcli", "agenda", "--help"], timeout=10))
        self.assertEqual(run.call_args_list[1], mock.call([
            "gcalcli", "agenda", "--json", "--nodeclined", "--details", "all",
            "2026-09-02", "2026-09-03"]))

    def test_released_cli_uses_tsv(self):
        with mock.patch.object(widget, "run_capped", side_effect=[
                "usage: gcalcli agenda [--tsv]\n", self.tsv("Ordinary")]) as run:
            rows = widget.parse_google_rows(DAY, DAY)
        self.assertEqual(rows[0]["calendar"], "Work")
        self.assertIn("--tsv", run.call_args.args[0])

    @staticmethod
    def tsv(description, ending="\n"):
        return ending.join([
            "start_date\tstart_time\tend_date\tend_time\ttitle\tdescription\tcalendar",
            "2026-09-02\t12:00\t2026-09-02\t13:00\tPartner sync\t" + description + "\tWork",
            "2026-09-02\t14:00\t2026-09-02\t15:00\tSecond meeting\tOrdinary\tPersonal", ""])

    def test_legacy_carriage_returns_and_unicode_keep_both_records(self):
        for separator in ("\r", "\u2028", "\u2029", "\x85"):
            for ending in ("\n", "\r\n"):
                with self.subTest(separator=separator, ending=ending), \
                        mock.patch.object(widget, "_google_json_support", False), \
                        mock.patch.object(widget, "run_capped", return_value=self.tsv(
                            "Before" + separator + "After", ending)):
                    rows = widget.parse_google_rows(DAY, DAY)
                    self.assertEqual([row["calendar"] for row in rows], ["Work", "Personal"])
                    self.assertEqual(rows[0]["description"], "Before" + separator + "After")
                    self.assertEqual(len(widget.build_day(rows, DAY)["events"]), 2)

    def test_legacy_ambiguous_row_does_not_return_a_partial_agenda(self):
        with mock.patch.object(widget, "_google_json_support", False), \
                mock.patch.object(widget, "run_capped", return_value=self.tsv("Before\tAfter")):
            self.assertIsNone(widget.parse_google_rows(DAY, DAY))
        self.assertEqual(widget.GOOGLE_ERROR, "google-tsv-ambiguous")

    def test_legacy_short_row_and_invalid_headers_are_rejected(self):
        for output in (self.tsv("Ordinary").replace("\tWork\n", "\n"),
                       self.tsv("Ordinary").replace("description\tcalendar", "calendar\tcalendar"),
                       "unexpected header\nvalue\n"):
            with self.subTest(output=output), \
                    mock.patch.object(widget, "_google_json_support", False), \
                    mock.patch.object(widget, "run_capped", return_value=output):
                self.assertIsNone(widget.parse_google_rows(DAY, DAY))

    def test_legacy_empty_response_and_header_only_remain_empty(self):
        for output in ("", self.tsv("Ordinary").partition("\n")[0] + "\n"):
            with self.subTest(output=output), \
                    mock.patch.object(widget, "_google_json_support", False), \
                    mock.patch.object(widget, "run_capped", return_value=output):
                self.assertEqual(widget.parse_google_rows(DAY, DAY), [])

    def test_ambiguity_is_exposed_in_the_panel_payload(self):
        output = io.StringIO()
        with mock.patch.object(widget, "ARGV", ["day", "0"]), \
                mock.patch.object(widget, "PROVIDER", "google"), \
                mock.patch.object(widget, "DEMO", False), \
                mock.patch.object(widget, "authenticated", return_value=True), \
                mock.patch.object(widget.shutil, "which", return_value="/usr/bin/gcalcli"), \
                mock.patch.object(widget, "_google_json_support", False), \
                mock.patch.object(widget, "run_capped", return_value=self.tsv("Before\tAfter")), \
                redirect_stdout(output):
            self.assertEqual(widget.main(), 0)
        payload = json.loads(output.getvalue())
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["error"], "google-tsv-ambiguous")
        self.assertEqual(payload["days"], [])

    def test_real_stdout_reader_preserves_json_text(self):
        event = dict(EVENT, description="Before\tAfter\r\nNext\u2028line")
        data = json.dumps([event], ensure_ascii=False).encode()
        raw = widget.run_capped([sys.executable, "-c",
                                "import sys;sys.stdout.buffer.write(" + repr(data) + ")"])
        self.assertEqual(widget.google_json_rows(raw)[0]["description"], event["description"])


if __name__ == "__main__":
    unittest.main()
