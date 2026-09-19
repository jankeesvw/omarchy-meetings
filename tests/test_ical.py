import importlib.machinery
import importlib.util
import os
import time
import unittest
from datetime import date, datetime
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request


ROOT = Path(__file__).resolve().parents[1]
os.environ["TZ"] = "Europe/London"
os.environ["MEETINGS_CONFIG"] = str(ROOT / "tests" / "missing-config.json")
time.tzset()

loader = importlib.machinery.SourceFileLoader(
    "meetings_widget", str(ROOT / "bin" / "meetings-widget"))
spec = importlib.util.spec_from_loader(loader.name, loader)
widget = importlib.util.module_from_spec(spec)
loader.exec_module(widget)


class ICalendarTests(unittest.TestCase):
    def test_datetime_z_is_converted_to_local_time(self):
        self.assertEqual(
            widget.parse_ics_datetime("20260901T090000Z"),
            datetime(2026, 9, 1, 10, 0),
        )

    def test_datetime_numeric_offset_is_converted_to_local_time(self):
        self.assertEqual(
            widget.parse_ics_datetime("20260901T090000+0200"),
            datetime(2026, 9, 1, 8, 0),
        )

    def test_datetime_tzid_is_converted_to_local_time(self):
        self.assertEqual(
            widget.parse_ics_datetime(
                "20260901T090000", {"TZID": "America/New_York"}),
            datetime(2026, 9, 1, 14, 0),
        )

    def test_weekly_rrule_expands_byday_and_honours_exdate(self):
        lines = [
            "UID:standup@example.com",
            "SUMMARY:Standup",
            "DTSTART:20260824T090000Z",
            "DTEND:20260824T091500Z",
            "RRULE:FREQ=WEEKLY;BYDAY=MO,WE",
            "EXDATE:20260909T090000Z",
        ]
        rows = widget.ical_event_rows(
            lines, "Work", date(2026, 9, 7), date(2026, 9, 13))
        self.assertEqual(
            [(row["start_date"], row["start_time"]) for row in rows],
            [("2026-09-07", "10:00")],
        )

    def test_utc_recurrence_tracks_local_dst_change(self):
        lines = [
            "UID:utc-weekly@example.com",
            "SUMMARY:UTC weekly",
            "DTSTART:20261019T090000Z",
            "DTEND:20261019T093000Z",
            "RRULE:FREQ=WEEKLY;COUNT=2",
        ]
        rows = widget.ical_event_rows(
            lines, "Work", date(2026, 10, 19), date(2026, 10, 26))
        self.assertEqual(
            [(row["start_date"], row["start_time"]) for row in rows],
            [("2026-10-19", "10:00"), ("2026-10-26", "09:00")],
        )

    def test_ical_attendees_are_embedded_in_event_payload(self):
        lines = [
            "UID:review@example.com",
            "SUMMARY:Review",
            "DTSTART:20260901T090000Z",
            "DTEND:20260901T100000Z",
            'ATTENDEE;CN="Alex Example";PARTSTAT=ACCEPTED:mailto:alex@example.com',
        ]
        row = widget.ical_event_rows(
            lines, "Work", date(2026, 9, 1), date(2026, 9, 1))[0]
        event = widget.event_from(row, date(2026, 9, 1))
        self.assertTrue(event["attendees_embedded"])
        self.assertEqual(event["attendees"], [{
            "name": "Alex Example",
            "email": "alex@example.com",
            "status": "accepted",
        }])


if __name__ == "__main__":
    unittest.main()


class FakeResponse:
    def __init__(self, url, body=b"BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"):
        self.url = url
        self.body = body

    def geturl(self):
        return self.url

    def read(self, limit=-1):
        return self.body if limit < 0 else self.body[:limit]

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeOpener:
    def __init__(self, response):
        self.response = response

    def open(self, request, timeout=None):
        return self.response


class ICalendarFeedTransportTests(unittest.TestCase):
    """The feed URL is the credential, so it may only ever travel over https."""

    def setUp(self):
        self.saved = (widget.ICAL_PATH, widget._ical_opener,
                      widget._ical_raw, widget._ical_checked)
        widget._ical_raw = None
        widget._ical_checked = False

    def tearDown(self):
        (widget.ICAL_PATH, widget._ical_opener,
         widget._ical_raw, widget._ical_checked) = self.saved

    def test_redirect_to_http_is_refused(self):
        handler = widget.HttpsOnlyRedirects()
        with self.assertRaises(URLError):
            handler.redirect_request(
                Request("https://calendar.example/feed.ics"), None, 302, "Found",
                {}, "http://calendar.example/feed.ics")

    def test_redirect_to_https_is_followed(self):
        handler = widget.HttpsOnlyRedirects()
        moved = handler.redirect_request(
            Request("https://calendar.example/feed.ics"), None, 302, "Found",
            {}, "https://cdn.example/feed.ics")
        self.assertEqual(moved.full_url, "https://cdn.example/feed.ics")

    def test_feed_that_landed_off_https_is_not_read(self):
        widget.ICAL_PATH = "https://calendar.example/feed.ics"
        widget._ical_opener = FakeOpener(
            FakeResponse("http://calendar.example/feed.ics"))
        self.assertIsNone(widget.read_ical_source())

    def test_feed_that_stayed_on_https_is_read(self):
        widget.ICAL_PATH = "https://calendar.example/feed.ics"
        widget._ical_opener = FakeOpener(
            FakeResponse("https://cdn.example/feed.ics"))
        self.assertEqual(widget.read_ical_source(),
                         "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")

    def test_http_feed_url_is_refused_before_any_request(self):
        widget.ICAL_PATH = "http://calendar.example/feed.ics"
        widget._ical_opener = FakeOpener(
            FakeResponse("https://calendar.example/feed.ics"))
        self.assertIsNone(widget.read_ical_source())

