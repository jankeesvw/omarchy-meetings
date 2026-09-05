import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Today's agenda as a day column, the way a calendar draws it:
// appointments in their place in time, a line for now, all-day events as bars
// above it.
//
// Why a timeline and not a list: a list tells you what there is, a column tells
// you what your day looks like. The gap between two appointments is
// information, and you only see it when the space between them is real space.
//
// The structure follows the Things widget: a Panel root for the lifecycle, a
// BarIconButton for the bar, a KeyboardPanel for the panel itself.
//
// Glyphs are \u escapes, because literal private-use characters do not always
// survive the trip to disk.
Panel {
  id: root

  moduleName: "jankeesvw.meetings"
  ipcTarget: "jankeesvw.meetings"

  // The script that does the talking sits next to this file, so the plugin
  // runs from wherever it was installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/meetings-widget").toString().replace(/^file:\/\//, "")

  readonly property string iconCalendar: "\uf073"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Always a list of days, in day mode too: then there is one of them. That way
  // the week draws the same column seven times instead of being a second view.
  property var days: []

  // Today and this week are kept between openings. The timers keep them fresh,
  // so there is something on screen the moment you open it and the refresh
  // happens behind that; otherwise you stare at an empty grid every time.
  property var todayCache: []
  property var weekCache: []
  property var upcoming: null
  property int nowMinutes: 0
  property bool reachable: true

  // Which day the panel is showing. 0 is today; the bar stays about today even
  // when you page forward.
  property int dayOffset: 0

  // Looking at a colleague's agenda instead of your own. Only for the day you
  // are viewing; the bar keeps reporting your own day.
  property bool showBorrowed: false
  // The week is the default: it says more at a glance than a single day, and it
  // is always ready because it is fetched in the background.
  property bool weekView: true
  property bool loading: false

  // The controls and every appointment form one ring that tab walks, in the
  // order they appear on screen: the week switch at the top, then the
  // appointments, then the borrowed calendar at the bottom. An all-day event is
  // an appointment too, only without a time, so it is in the ring as well.
  property int cursor: -1

  readonly property var ring: {
    var out = []
    for (var d = 0; d < days.length; d++) {
      var day = days[d]
      for (var a = 0; a < day.allday.length; a++) out.push(day.allday[a])
      for (var t = 0; t < day.events.length; t++) out.push(day.events[t])
    }
    return out
  }

  // De afspraak waar je nu heen zou gaan: hij loopt, of hij begint zo. Vijf
  // minuten, want daarbuiten is joinen geen actie maar een vergissing. Zonder
  // videolink valt er niets te joinen, hoe dichtbij hij ook is.
  readonly property int joinWindow: 5

  readonly property var joinable: {
    if (!upcoming) return null
    if (safeUrl(upcoming.hangout) === "") return null
    if (inMeeting) return upcoming
    return minutesUntil <= joinWindow ? upcoming : null
  }

  readonly property bool hasJoin: joinable !== null

  // De knop staat vooraan in de ring als hij er is: dat is het eerste wat je
  // wilt kunnen doen als je het paneel opent, en dan schuift de rest een op.
  readonly property int weekIndex: hasJoin ? 1 : 0
  readonly property int firstEventIndex: weekIndex + 1

  readonly property int ringLength: detailEvent
    ? Math.max(1, detailActions.length)
    : ring.length + 2 + (hasJoin ? 1 : 0) + (hasBorrowed ? 1 : 0)
  readonly property bool onJoin: !detailEvent && hasJoin && cursor === 0
  readonly property bool onWeekToggle: !detailEvent && cursor === weekIndex
  readonly property bool onCalendarPicker:
    !detailEvent && cursor === firstEventIndex + ring.length
  readonly property bool onBorrowedToggle: !detailEvent && hasBorrowed && cursor === ringLength - 1
  readonly property var cursorEvent:
    (!detailEvent && cursor >= firstEventIndex && cursor < firstEventIndex + ring.length)
      ? ring[cursor - firstEventIndex] : null

  // Every appointment that has a time, across all shown days. Decides how far
  // the time axis runs, so every day in the week shares the same axis.
  readonly property var allTimed: {
    var out = []
    for (var d = 0; d < days.length; d++)
      for (var t = 0; t < days[d].events.length; t++) out.push(days[d].events[t])
    return out
  }

  readonly property bool emptyDay: {
    for (var d = 0; d < days.length; d++)
      if (days[d].events.length > 0 || days[d].allday.length > 0) return false
    return true
  }
  // Whose calendar you can borrow comes from the config file, by way of the
  // script: a plugin should not have a colleague's name compiled into it.
  // Empty means nobody is configured, and then the toggle is left out.
  property string borrowedCalendar: ""
  property string borrowedLabel: ""

  // Every calendar there is, and which of them you want to see. An empty
  // selection means nothing has ever been unticked, and then they are all on.
  // One appointment expanded. It floats over the grid rather than replacing it:
  // the context you just used to point at that appointment is the thing you
  // least want to lose while you read it.
  property var detailEvent: null

  readonly property var detailActions: {
    if (!detailEvent) return []
    var out = []
    if (safeUrl(detailEvent.hangout) !== "")
      out.push({ label: "Join the call", url: safeUrl(detailEvent.hangout) })
    if (safeUrl(detailEvent.link) !== "")
      out.push({ label: "Open in " + calendarProviderLabel, url: safeUrl(detailEvent.link) })
    return out
  }

  property var calendars: []
  property var visibleCalendars: []
  readonly property var checkedCalendars:
    (visibleCalendars && visibleCalendars.length > 0) ? visibleCalendars : calendars
  // A write of your own must not be overwritten by an answer that was already
  // on its way when you ticked the box.
  property bool writingCalendars: false

  // The remembered week or day choice applies once, when the data first lands.
  property bool viewApplied: false
  property bool writingView: false
  readonly property bool hasBorrowed: borrowedCalendar !== ""
  property string datePath: ""
  property string dateLabel: ""
  property string calendarProvider: "google"
  property string calendarProviderLabel: "Google Calendar"
  property string agendaUrl: ""

  // The colour the old waybar module gave a meeting that is about to start. The
  // same colour draws the line for now: the theme accent is already spoken for
  // by today and by the selection, and three things in one colour reads as
  // nothing at all.
  readonly property color urgentFill: "#f7768e"
  readonly property int urgentMinutes: 5

  // Minutes until the appointment starts; negative once it is running.
  readonly property int minutesUntil: upcoming ? upcoming.start_minutes - nowMinutes : 0
  readonly property bool inMeeting: upcoming !== null && minutesUntil <= 0
  readonly property bool almostDue: upcoming !== null && minutesUntil > 0 && minutesUntil <= urgentMinutes

  // "in 25m", "in 1h30m", "25m left" once it is running. The waybar module
  // read the same way, and it beats a bare start time: what you want to know
  // is how much time you have, not what the clock will say.
  function humanDelta(minutes) {
    var m = Math.max(0, minutes)
    if (m < 60) return m + "m"
    return Math.floor(m / 60) + "h" + (m % 60 < 10 ? "0" : "") + (m % 60) + "m"
  }

  readonly property string countdown: {
    if (!upcoming) return ""
    if (inMeeting) return humanDelta(upcoming.end_minutes - nowMinutes) + " left"
    return "in " + humanDelta(minutesUntil)
  }

  // The visible span of time. Wide enough for the working day, and stretched
  // when something falls outside it, so an early or late appointment does not
  // quietly drop off the screen.
  readonly property int dayStart: {
    var earliest = 7 * 60
    for (var i = 0; i < allTimed.length; i++) earliest = Math.min(earliest, allTimed[i].start_minutes - 30)
    return Math.max(0, Math.min(earliest, nowMinutes - 60))
  }

  readonly property int dayEnd: {
    var latest = 23 * 60
    for (var i = 0; i < allTimed.length; i++) latest = Math.max(latest, allTimed[i].end_minutes + 30)
    return Math.min(24 * 60, Math.max(latest, nowMinutes + 60))
  }

  readonly property int daySpan: Math.max(60, dayEnd - dayStart)

  // The height of one hour. Decides whether you can read duration off the grid:
  // with too little room every block ends up the same height, and that is
  // exactly the information a timeline exists to show.
  // The axis fills exactly what is left over, whatever the day holds. That way
  // the panel is always the same height: a day that runs to midnight gets
  // narrower hours, an extra row of all-day events takes height off the axis. A
  // panel with a different height per day jumps out from under your mouse, and
  // on opening you would watch it grow the moment the data arrived.
  //
  // Everything above and below the axis is measured rather than guessed. Those
  // heights do not depend on the hour height, so this does not bite itself.
  readonly property int hourHeight: {
    var hours = Math.max(1, daySpan / 60)
    var chrome = dateHeader.height + dayNamesRow.height + alldayRow.height
                 + calendarPicker.height + borrowedToggle.height
                 + content.spacing * (root.hasBorrowed ? 5 : 4)
                 + panel.verticalContentInset
                 + Style.space(10)
    var room = panel.maxCardHeight - chrome
    return Math.max(Style.space(16), room / hours)
  }

  // The width of the hour column on the left. It sits outside the days, so
  // every day of a week shares the same axis.
  readonly property int gutter: Style.space(34)
  readonly property real columnWidth: content.width > 0
    ? (content.width - gutter) / Math.max(1, days.length) : 0

  // Every day gets the same room for all-day events, even when only one day has
  // any: otherwise the axis shifts up or down from column to column.
  readonly property int alldayHeight: Style.space(17)

  readonly property string clockText: {
    var h = Math.floor(nowMinutes / 60)
    var m = nowMinutes % 60
    return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
  }
  readonly property int alldayRows: {
    var most = 0
    for (var d = 0; d < days.length; d++) most = Math.max(most, days[d].allday.length)
    return most
  }

  // Panel is a bare Item, so without this size the bar gives the widget zero
  // width and it is both invisible and unclickable.
  readonly property int barSlot: barLabel === ""
    ? Style.bar.iconSlot
    : Math.ceil(labelMetrics.advanceWidth) + Style.space(22)

  TextMetrics {
    id: labelMetrics
    text: root.barLabel
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
  implicitWidth: bar && bar.vertical ? (bar ? bar.barSize : Style.bar.sizeHorizontal) : barSlot
  implicitHeight: bar && bar.vertical ? barSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  // The title is cut at 20 characters, as it always was: any longer pushes the
  // rest of the bar aside for something you read in the panel anyway.
  readonly property string barLabel: {
    if (!reachable) return ""
    // Say so when the day is empty. A bare icon is indistinguishable from a
    // calendar that is still loading, and having nothing left on the schedule
    // is exactly the thing you want to be sure about.
    if (!upcoming) return "Nothing planned"
    var title = upcoming.title.length > 20 ? upcoming.title.substring(0, 20) + "…" : upcoming.title
    return title + " @ " + upcoming.start + " " + countdown
  }

  // A fetch that is already running is out of date: you have picked another day
  // or calendar in the meantime. Letting it finish and doing nothing left the
  // grid empty until the next minute, so it is cut short and the new one starts
  // as soon as it is gone.
  property bool refreshPending: false
  property bool aborting: false

  function refresh() {
    if (listProc.running) {
      refreshPending = true
      aborting = true
      listProc.running = false
      return
    }
    var argv = [root.script, weekView ? "week" : "day", String(dayOffset)]
    if (showBorrowed) argv.push("--only", borrowedCalendar)
    listProc.command = argv
    listProc.running = true
    loading = true
  }

  // The grid is there before the calendar CLI has said anything: the same days, the same
  // dates, only without appointments yet. A week that appears only once the data
  // lands feels slow, while the grid itself is already settled the moment you
  // flip the switch.
  function skeleton() {
    var today = new Date()
    var base = new Date()
    if (weekView) base.setDate(base.getDate() - ((base.getDay() + 6) % 7) + dayOffset * 7)
    else base.setDate(base.getDate() + dayOffset)

    var locale = Qt.locale("en_US")
    var out = []
    for (var i = 0; i < (weekView ? 7 : 1); i++) {
      var d = new Date(base.getFullYear(), base.getMonth(), base.getDate() + i)
      out.push({
        // Without leading zeroes, same as the script, because that is how
        // Google Calendar wants it in its url.
        date_path: d.getFullYear() + "/" + (d.getMonth() + 1) + "/" + d.getDate(),
        calendar_url: calendarViewUrl(
          d.getFullYear() + "/" + (d.getMonth() + 1) + "/" + d.getDate(), "day"),
        date_label: d.toLocaleDateString(locale, "dddd d MMMM"),
        short_label: d.toLocaleDateString(locale, "ddd d"),
        range_label: d.toLocaleDateString(locale, "d MMM"),
        is_today: d.getFullYear() === today.getFullYear()
                  && d.getMonth() === today.getMonth()
                  && d.getDate() === today.getDate(),
        events: [],
        allday: [],
      })
    }

    days = out
    datePath = out[0].date_path
    dateLabel = weekView ? out[0].range_label + " - " + out[6].range_label
                         : out[0].date_label
    agendaUrl = calendarViewUrl(datePath, weekView ? "week" : "day")
  }

  function refreshToday() {
    if (listProc.running) return
    listProc.command = [root.script, "day", "0"]
    listProc.running = true
  }

  // Keeping the week warm on its own, separate from the panel. Fetching seven
  // days takes a couple of seconds, and that is not a price you want to pay at
  // the moment you open it.
  function refreshWeek() {
    if (weekProc.running) return
    weekProc.command = [root.script, "week", "0"]
    weekProc.running = true
  }

  // The tick has to be where you put it straight away; the script and the grid
  // follow. Everything on is the same as nothing chosen, and that is written as
  // an empty list so a new calendar joins on its own.
  function applyCalendars(values) {
    writingCalendars = true
    visibleCalendars = (values.length === calendars.length) ? [] : values

    var argv = [root.script, "set-calendars"]
    for (var i = 0; i < visibleCalendars.length; i++) argv.push(visibleCalendars[i])
    calendarProc.command = argv
    calendarProc.running = true
  }

  function toggleBorrowed() {
    if (!hasBorrowed) return
    showBorrowed = !showBorrowed
    cursor = ringLength - 1
    skeleton()
    refresh()
  }

  // The whole week in view. The panel widens and the days sit side by side on
  // the same axis; the offset then counts in weeks.
  function toggleWeek() {
    weekView = !weekView
    dayOffset = 0
    cursor = 0

    // Onthouden waar je hem liet staan. Lokaal eerst, het schrijven daarna:
    // de schakelaar hoort niet te wachten op een proces.
    writingView = true
    viewProc.command = [root.script, "set-view", weekView ? "week" : "day"]
    viewProc.running = true

    skeleton()
    refresh()
  }

  // Tab wraps around, the controls included.
  function tabStep(direction) {
    if (cursor < 0) cursor = direction > 0 ? 0 : ringLength - 1
    else cursor = (cursor + direction + ringLength) % ringLength
  }

  function goDay(delta) {
    dayOffset += delta
    cursor = -1
    // Do not leave yesterday standing under a new date, but do not go blank
    // either: the empty grid of the new day.
    skeleton()
    refresh()
  }

  function applyPayload(text) {
    // Half-truncated output from a cancelled fetch is not an answer.
    if (aborting) return
    try {
      var data = JSON.parse(text)
      reachable = data.ok === true
      blockedReason = data.ok === true ? "" : String(data.error || "")
      if (data.ok === true) copiedPrompt = false
      var incoming = data.days || []
      var ownAndCurrent = data.offset === 0 && !data.only_calendar
      var isPlainToday = data.mode === "day" && ownAndCurrent
      var isPlainWeek = data.mode === "week" && ownAndCurrent
      if (isPlainToday) todayCache = incoming
      if (isPlainWeek) weekCache = incoming

      // Only take this on when the answer matches what you are looking at now.
      // A slow answer about yesterday must not overwrite today, and with the
      // panel closed the cache stays as it is.
      if (opened && data.mode === (weekView ? "week" : "day")
          && data.offset === dayOffset && !!data.only_calendar === showBorrowed) {
        days = incoming
      } else if (!opened && (weekView ? isPlainWeek : isPlainToday)) {
        days = incoming
      }

      nowMinutes = data.now_minutes || 0
      datePath = data.date_path || ""
      dateLabel = data.date_label || ""
      calendarProvider = data.provider || "google"
      calendarProviderLabel = data.provider_label || "Google Calendar"
      agendaUrl = data.agenda_url || ""
      // Whose calendar can be borrowed lives in the config file, which only the
      // script reads, so it arrives with the agenda rather than separately.
      borrowedCalendar = (data.borrowed && data.borrowed.name) || ""
      borrowedLabel = (data.borrowed && data.borrowed.label) || ""
      calendars = data.calendars || []
      // Alleen de eerste keer: daarna is de schakelaar in het paneel de baas,
      // en zou een antwoord dat al onderweg was je klik terugdraaien.
      if (!viewApplied && data.view) {
        weekView = data.view === "week"
        viewApplied = true
      }
      if (!writingCalendars) visibleCalendars = data.visible || []
      // The bar is about today: paging around in the panel must not change it,
      // or the countdown stops meaning anything.
      if (data.is_today && !showBorrowed) upcoming = data.upcoming || null
      if (cursor >= ringLength) cursor = -1
    } catch (e) {
      reachable = false
    }
  }

  // The week view of the day you are looking at, when you are not pointing at
  // anything in particular.
  // The links come from the calendar, so they are input. Check the whole shape
  // and launch it as one argv value: Outlook event URLs contain ampersands,
  // which a shell command string would otherwise interpret as control syntax.
  function safeUrl(value) {
    var url = String(value || "")
    return /^https:\/\/[A-Za-z0-9.-]+\/[A-Za-z0-9._~:\/?#@!$&'()*+,;=%-]*$/.test(url) ? url : ""
  }

  // The date path is built by our own script out of a year, a month and a day,
  // so this only has to catch a payload that is not ours at all.
  function safeDatePath(value) {
    var path = String(value || "")
    return /^[0-9]{4}\/[0-9]{1,2}\/[0-9]{1,2}$/.test(path) ? path : ""
  }

  function calendarViewUrl(path, mode) {
    var view = mode === "day" ? "day" : "week"
    if (calendarProvider === "microsoft")
      return "https://outlook.office.com/calendar/view/" + view
    var safePath = safeDatePath(path)
    return safePath === "" ? "" :
      "https://calendar.google.com/calendar/u/0/r/" + view + "/" + safePath
  }

  function openAgenda() {
    openUrl(agendaUrl)
  }

  // Opening a single day in the configured calendar. The week is already in front of
  // you, so pointing at a day name means you want that day itself.
  function openDay(day) {
    if (!bar || !day) return
    openUrl(day.calendar_url)
  }

  // Opening one appointment. If there is a Meet link, that is the one you want:
  // you click a call to get into it, not to read when it is. Without a Meet
  // link, the detail page, where the rest of the appointment lives.
  // Enter used to jump straight to the browser. Everything the calendar knows
  // about an appointment comes first now, and the browser is one of the buttons.
  // When, as one line: the times and how long it runs.
  readonly property string detailWhen: {
    if (!detailEvent) return ""
    if (detailEvent.allday) return "All day"
    var minutes = detailEvent.minutes || 0
    return detailEvent.start + " to " + detailEvent.end + ", " + spanLabel(minutes)
  }

  // Which calendar it came from. The colour already says so to anyone who knows
  // the colours, but here there is room to simply write it down.
  readonly property string detailCalendar:
    detailEvent ? String(detailEvent.calendar || "") : ""

  // Google and Microsoft fetch these when an appointment opens. iCalendar
  // already supplied them with the agenda, avoiding a second feed download.
  property var detailAttendees: []

  // Where the pointed-at block sits, in panel coordinates. The card hangs off
  // that rather than appearing in the middle: you want to see which appointment
  // you are on, and in a week the middle says nothing.
  property real detailAnchorX: 0
  property real detailAnchorY: 0
  property real detailAnchorHeight: 0

  // The block the cursor is on, so the card knows where it belongs.
  property var cursorItem: null

  function measureAnchor() {
    if (!cursorItem) return
    var point = cursorItem.mapToItem(keyCatcher, 0, 0)
    detailAnchorX = point.x
    detailAnchorY = point.y
    detailAnchorHeight = cursorItem.height
  }
  property bool loadingAttendees: false

  function statusMark(status) {
    if (status === "accepted") return "\u2713"
    if (status === "declined") return "\u2717"
    if (status === "tentative") return "?"
    return "\u00b7"
  }

  function statusColor(status) {
    if (status === "declined") return root.urgent
    return root.foreground
  }

  // A Repeater does not hand back the same object reference that went into the
  // list, so comparing with === is always false and the cursor colours nothing.
  // Compare on what makes an appointment unique instead.
  // Minutes as "2h 30m", or only the part that is there.
  function spanLabel(minutes) {
    var hours = Math.floor(minutes / 60)
    var rest = minutes % 60
    if (hours > 0 && rest > 0) return hours + "h " + rest + "m"
    if (hours > 0) return hours + "h"
    return rest + "m"
  }

  function sameEvent(a, b) {
    if (!a || !b) return false
    if (a.id && b.id && String(a.id) !== "") return a.id === b.id
    return a.title === b.title
           && a.calendar === b.calendar
           && a.start_epoch === b.start_epoch
           && a.allday === b.allday
  }

  // Waarom het paneel leeg is, in de woorden van het script.
  property string blockedReason: ""
  property bool copiedPrompt: false

  readonly property string blockedTitle: {
    if (blockedReason === "ical-path-missing") return "iCalendar feed is not configured"
    if (blockedReason === "ical-unavailable") return "iCalendar feed is unreachable"
    if (blockedReason === "ical-insecure") return "iCalendar feed is not on https"
    if (blockedReason === "m365-missing") return "CLI for Microsoft 365 is not installed"
    if (blockedReason === "gcalcli-missing") return "gcalcli is not installed"
    if (blockedReason === "not-authenticated") return "Not signed in to " + calendarProviderLabel
    return "Calendar unreachable"
  }

  readonly property string blockedHint: {
    if (blockedReason === "ical-path-missing")
      return "Set provider to ical and add icalPath in the widget config."
    if (blockedReason === "ical-unavailable")
      return "Check that the configured .ics file or webcal URL is reachable."
    if (blockedReason === "ical-insecure")
      return "A subscribed feed URL is the key to the whole calendar.\nUse https or webcal, not http."
    if (blockedReason === "m365-missing")
      return "This widget reads Outlook through the m365 CLI.\nInstall @pnp/cli-microsoft365 with npm."
    if (blockedReason === "gcalcli-missing")
      return "This widget reads your calendar through gcalcli.\nInstall it with: yay -S gcalcli"
    if (blockedReason === "not-authenticated")
      return calendarProvider === "microsoft"
        ? "Run m365 setup, then m365 login in a terminal.\nThe Entra app needs delegated Calendars.Read permission."
        : "Run gcalcli init in a terminal.\nIt opens your browser once and stores a token."
    return calendarProvider === "microsoft"
      ? "m365 is signed in, but Outlook returned nothing. Check Calendars.Read permission."
      : "gcalcli is installed and signed in, but returned nothing."
  }

  // Wat je aan een agent geeft. Een opdracht en geen uitleg: het moet iets zijn
  // dat uitgevoerd kan worden zonder dat er nog iets nagevraagd hoeft te worden.
  readonly property string setupPrompt: calendarProvider === "ical" ?
    "Set up the omarchy-meetings bar widget for an iCalendar feed on this Omarchy machine.\n\n" +
    "Write ~/.config/omarchy-meetings/config.json with provider set to ical and " +
    "icalPath set to my local .ics file or https/webcal calendar URL. Confirm it worked " +
    "by running meetings-widget week. Do not copy the private feed URL anywhere else." :
    calendarProvider === "microsoft" ?
    "Set up the omarchy-meetings bar widget for Outlook Calendar on this Omarchy machine.\n\n" +
    "1. Install the CLI: npm i -g @pnp/cli-microsoft365\n" +
    "2. Run: m365 setup\n   Choose scripting and the minimal User.Read permission.\n" +
    "3. In Microsoft Entra, add delegated Microsoft Graph Calendars.Read permission to that app.\n" +
    "4. Run: m365 login\n" +
    "5. Confirm it worked: m365 status --output json\n\n" +
    "Keep { \"provider\": \"microsoft\" } in ~/.config/omarchy-meetings/config.json. " +
    "The widget calls Microsoft Graph through m365 and reuses its login; do not create another token." :
    "Set up the omarchy-meetings bar widget on this machine. It reads my Google Calendar " +
    "through gcalcli, and it is not working yet.\n\n" +
    "1. Install gcalcli if it is missing. On Arch or Omarchy: yay -S gcalcli\n" +
    "2. Run: gcalcli init\n   This opens a browser once and asks for calendar access.\n" +
    "3. Confirm it worked: gcalcli list should print my calendars.\n\n" +
    "The widget needs nothing else. It calls gcalcli and reuses the token that init " +
    "stores in ~/.local/share/gcalcli, so there is no second login.\n\n" +
    "If you want to colour my calendars, write ~/.config/omarchy-meetings/config.json " +
    "with a \"calendars\" list: each entry has \"match\" (a regular expression tried " +
    "against the calendar name as gcalcli list prints it), \"color\" and \"priority\"."

  // Rood in drie sterktes: een licht vlak, een donkere rand eromheen, en tekst
  // die op dat vlak leesbaar blijft. De rand moet donkerder zijn dan de vulling,
  // anders leest hij als een gloed in plaats van als een omtrek.
  readonly property color joinFill: Qt.rgba(urgentFill.r, urgentFill.g, urgentFill.b, 0.38)
  readonly property color joinFillHot: Qt.rgba(urgentFill.r, urgentFill.g, urgentFill.b, 0.52)
  readonly property color joinBorder: Qt.darker(urgentFill, 2.1)
  readonly property color joinInk: Qt.lighter(urgentFill, 1.35)

  readonly property string joinLabel: {
    if (!joinable) return ""
    var title = String(joinable.title || "")
    if (inMeeting) return "Join " + title
    return "Join " + title + ", starts in " + humanDelta(minutesUntil)
  }

  // Waar dit hele ding om begon: zien wanneer de volgende is, en er heen.
  function joinNow() {
    if (!joinable) return
    openUrl(joinable.hangout)
  }

  function copySetupPrompt() {
    copyProc.command = ["wl-copy", "--", root.setupPrompt]
    copyProc.running = true
    copiedPrompt = true
  }

  function showDetail(event) {
    if (!event) return
    measureAnchor()
    detailEvent = event
    cursor = 0

    detailAttendees = Array.isArray(event.attendees) ? event.attendees : []
    if (event.attendees_embedded === true) return
    var id = String(event.id || "")
    var calendar = String(event.calendar || "")
    if (id === "" || calendar === "") return

    loadingAttendees = true
    attendeesProc.command = [root.script, "attendees", calendar, id]
    attendeesProc.running = true
  }

  function closeDetail() {
    detailAttendees = []
    var previous = detailEvent
    detailEvent = null
    // Back on the appointment you came from, not at the top of the ring.
    var index = ring.indexOf(previous)
    cursor = index >= 0 ? firstEventIndex + index : 0
  }

  function openUrl(url) {
    var safe = safeUrl(url)
    if (safe === "") return
    close()
    Util.execArgv(["omarchy-launch-webapp", safe])
  }

  function openEvent(event) {
    showDetail(event)
  }

  function openSelected() {
    if (detailEvent) {
      var action = detailActions[cursor]
      if (action) openUrl(action.url)
      return
    }
    if (onJoin) { joinNow(); return }
    if (onWeekToggle) { toggleWeek(); return }
    if (onCalendarPicker) { calendarPicker.toggle(); return }
    if (onBorrowedToggle) { toggleBorrowed(); return }
    if (cursorEvent) openEvent(cursorEvent)
    else if (upcoming) openEvent(upcoming)
    else openAgenda()
  }

  // The arrows walk the same ring as tab, but skip the controls and stop at the
  // ends: up and down through a list should not wrap, and a switch is not an
  // appointment.
  function moveSelection(delta) {
    if (ring.length === 0) return
    if (cursorEvent === null) {
      // The first pick is the appointment you are in or heading for, not
      // bluntly the first of the day.
      var start = 1
      for (var i = 0; i < ring.length; i++) {
        if (ring[i] === upcoming) { start = 1 + i; break }
      }
      cursor = start
      return
    }
    cursor = Math.max(1, Math.min(ring.length, cursor + delta))
  }

  onOpenedChanged: {
    if (opened) {
      // Always start on today: where you left off yesterday is rarely where
      // you want to be now.
      dayOffset = 0
      showBorrowed = false
      detailEvent = null
      cursor = -1
      // What is left over from last time is this week, and that is exactly
      // what you want to see. If there is nothing yet, then at least the
      // empty grid.
      var cached = weekView ? weekCache : todayCache
      if (cached.length > 0) days = cached
      else skeleton()
      refresh()
    }
  }

  // Synthetic clicks are not reliable on the bar, so the keyboard ring can only
  // be tested by driving it from the inside. This handler only sets the cursor
  // position and calls what Enter would call; it reads nothing and runs nothing.
  IpcHandler {
    target: "jankeesvw.meetings.test"

    function cursorTo(index: int): string {
      root.cursor = index
      return JSON.stringify({ cursor: root.cursor, ringLength: root.ringLength,
                              onWeek: root.onWeekToggle, onPicker: root.onCalendarPicker,
                              onBorrowed: root.onBorrowedToggle })
    }

    function tab(direction: int): string {
      root.tabStep(direction)
      return JSON.stringify({ cursor: root.cursor, onWeek: root.onWeekToggle,
                              onPicker: root.onCalendarPicker })
    }

    function activate(): string {
      root.openSelected()
      return JSON.stringify({ cursor: root.cursor, pickerOpen: calendarPicker.popupOpen,
                              weekView: root.weekView })
    }

    function state(): string {
      return JSON.stringify({ cursorTitle: root.cursorEvent ? root.cursorEvent.title : null,
                              ringFirst: root.ring.length > 0 ? root.ring[0].title : null,
                              anchorX: Math.round(root.detailAnchorX),
                              anchorY: Math.round(root.detailAnchorY),
                              anchorH: Math.round(root.detailAnchorHeight),
                              cardX: Math.round(detailCard.x), cardY: Math.round(detailCard.y),
                              ringLength: root.ringLength, cursor: root.cursor,
                              calendars: root.calendars, visible: root.visibleCalendars,
                              checked: root.checkedCalendars,
                              pickerOpen: calendarPicker.popupOpen })
    }
  }

  Process {
    id: copyProc
  }

  Process {
    id: viewProc
    onExited: function(exitCode) { root.writingView = false }
  }

  Process {
    id: attendeesProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.loadingAttendees = false
        try {
          var parsed = JSON.parse(text)
          if (Array.isArray(parsed)) root.detailAttendees = parsed
        } catch (e) {
          root.detailAttendees = []
        }
      }
    }
    onExited: function(exitCode) { root.loadingAttendees = false }
  }

  Process {
    id: calendarProc
    onExited: function(exitCode) {
      root.writingCalendars = false
      root.skeleton()
      root.refresh()
      root.refreshWeek()
    }
  }

  Process {
    id: weekProc
    stdout: StdioCollector {
      onStreamFinished: root.applyPayload(text)
    }
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      onStreamFinished: root.applyPayload(text)
    }
    onExited: function(exitCode) {
      root.loading = false
      if (root.aborting) root.aborting = false
      else if (exitCode !== 0) root.reachable = false

      if (root.refreshPending) {
        root.refreshPending = false
        root.refresh()
      }
    }
  }

  // Every minute, so the now line keeps up. The calendar itself rarely changes,
  // but fetching again is cheap enough to do both at once.
  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    // With the panel closed this is about the bar, and the bar is always about
    // your own day today, whatever you were looking at last time.
    onTriggered: root.opened ? root.refresh() : root.refreshToday()
  }

  Timer {
    interval: 1800000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshWeek()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: root.barSlot
    opticalSize: root.barLabel === "" ? Style.bar.iconCanvas : root.barSlot
    opacity: root.reachable ? 1 : 0.5
    // While the appointment is running the bar stands out; otherwise it is a
    // look ahead.
    active: root.current !== null
    tooltipText: ""

    iconComponent: Component {
      Item {
        // Nearly time: the whole pill colours, the way the old module did. A
        // tint on the text alone is invisible out of the corner of your eye.
        Rectangle {
          anchors.centerIn: parent
          width: barRow.implicitWidth + Style.space(8)
          height: Style.space(18)
          radius: Style.cornerRadius
          visible: root.almostDue
          color: root.urgentFill
        }

        Row {
          id: barRow
          anchors.centerIn: parent
          spacing: Style.space(5)

          // The calendar colour, in place of the emoji square it used to be.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.upcoming !== null && !root.almostDue
            width: Style.space(7)
            height: Style.space(7)
            radius: width / 2
            color: root.upcoming ? root.upcoming.color : "transparent"
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            visible: root.upcoming === null
            text: root.iconCalendar
            font.family: root.fontFamily
            font.pixelSize: Style.bar.iconFont
            renderType: Text.NativeRendering
            color: root.foreground
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            visible: root.barLabel !== ""
            text: root.barLabel
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
            color: root.almostDue ? Color.background
                                  : (root.inMeeting ? root.urgent : root.foreground)
          }
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Worked out without the helper, so switching to the week resizes the card
    // straight away instead of only on the next opening.
    // Zonder agenda is er niets om zeven dagen breed voor te zijn: dan staat er
    // een zin en een knop, en die hoeven de halve breedte van je scherm niet.
    readonly property int desiredWidth:
      Style.space(!root.reachable ? 420 : (root.weekView ? 1000 : 340))
    contentWidth: Math.min(desiredWidth,
                           panel.availableCardWidth > 0 ? panel.availableCardWidth : desiredWidth)
    // A fixed height, because the hour height fills whatever is left: the day
    // always fits entirely, however late it runs. The screen is only the upper
    // bound for when there is less room than this.
    readonly property real maxCardHeight: Math.min(Style.space(620),
      availableCardHeight > 0 ? availableCardHeight : Style.space(620))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, maxCardHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the picker is open the arrows and Enter belong to it: otherwise
      // the panel pages along behind the popup.
      blocked: calendarPicker.popupOpen
      onCloseRequested: {
        if (root.detailEvent) root.closeDetail()
        else root.close()
      }
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.goDay(dx)
        else if (dy !== 0) root.moveSelection(dy)
      }
      onTabRequested: function(direction) { root.tabStep(direction) }
      // Activate only: Enter sends returnRequested and activateRequested both,
      // and a switch would flip straight back.
      onActivateRequested: root.openSelected()

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(8)

        // Waar het allemaal om begon: zien wanneer de volgende is, en er heen
        // kunnen. Bovenaan en niet ergens in het raster, want als er iets te
        // joinen valt is dat het enige wat je op dat moment wilt.
        // The date header with paging. Left and right do what the arrow keys do.
        Item {
          id: dateHeader
          width: parent.width
          // Hoog genoeg voor de knop als die er is: hem een eigen regel geven
          // duwde de hele agenda omlaag terwijl hier ruimte over was.
          height: Math.max(dateText.implicitHeight + Style.space(6),
                           root.hasJoin ? joinShape.height + Style.space(4) : 0)

          // The view choice belongs in the bar you also page with, not in a row
          // of its own below it: one line of chrome instead of two, and the
          // switch sits next to the buttons it most resembles.
          Text {
            textFormat: Text.PlainText
            id: weekLabel
            visible: root.reachable
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Week"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: root.weekView ? 0.9 : 0.55
          }

          ToggleSwitch {
            id: weekToggle
            visible: root.reachable
            anchors.left: weekLabel.right
            anchors.leftMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            checked: root.weekView
            hasCursor: root.onWeekToggle
            foreground: root.foreground
            scale: 0.75
            transformOrigin: Item.Left
            onToggled: root.toggleWeek()
          }

          Text {
            textFormat: Text.PlainText
            id: prevArrow
            visible: root.reachable
            anchors.left: weekToggle.right
            anchors.leftMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf053"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.5
            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(6)
              onClicked: root.goDay(-1)
            }
          }

          Text {
            textFormat: Text.PlainText
            id: dateText
            anchors.centerIn: parent
            // In de dagweergave is het paneel smal, en dan botst "Monday 31
            // August" op de knop. Dan maar de korte vorm: de datum is daar het
            // minst belangrijke van de twee.
            text: (root.hasJoin && !root.weekView && root.days.length > 0)
                    ? String(root.days[0].short_label || root.dateLabel)
                    : root.dateLabel
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: root.dayOffset === 0 ? 1 : 0.7

            MouseArea {
              id: dateMouse
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openAgenda()

              PanelToolTip {
                visible: dateMouse.containsMouse
                text: "Open in " + root.calendarProviderLabel
                fontFamily: root.fontFamily
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: dateText.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            visible: root.loading
            // nf-md-loading, past the BMP so written as a surrogate pair
            text: "\udb82\udd96"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.6

            RotationAnimator on rotation {
              running: root.loading
              from: 0
              to: 360
              duration: 1000
              loops: Animation.Infinite
            }
          }

          Text {
            textFormat: Text.PlainText
            id: nextArrow
            visible: root.reachable
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf054"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.5
            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(6)
              onClicked: root.goDay(1)
            }
          }

          // In dezelfde regel als de datum en de pijlen, aan de kant waar je
          // toch al klikt.
          Rectangle {
            id: joinShape
            visible: root.hasJoin
            anchors.right: nextArrow.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            width: joinContent.implicitWidth + Style.space(20)
            height: joinContent.implicitHeight + Style.space(10)
            radius: Style.cornerRadius
            color: joinMouse.containsMouse || root.onJoin ? root.joinFillHot : root.joinFill
            border.width: Math.max(1, Style.normalBorderWidth)
            border.color: root.joinBorder

            Behavior on color { ColorAnimation { duration: 100 } }

            Row {
              id: joinContent
              anchors.centerIn: parent
              spacing: Style.space(7)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                // nf-fa-video_camera
                text: "\uf03d"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.joinInk
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "Join meeting"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.joinInk
              }
            }

            MouseArea {
              id: joinMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.joinNow()
            }
          }

        }

        // Column headers. In day mode the day is already in the title bar.
        Row {
          id: dayNamesRow
          width: parent.width
          height: visible ? implicitHeight : 0
          visible: root.weekView && root.reachable

          Item { width: root.gutter; height: 1 }

          Repeater {
            model: root.days

            Item {
              id: dayHeader
              required property var modelData
              width: root.columnWidth
              height: dayName.implicitHeight + Style.space(4)

              MouseArea {
                id: dayHeaderMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openDay(dayHeader.modelData)

                PanelToolTip {
                  visible: dayHeaderMouse.containsMouse
                  text: dayHeader.modelData.date_label + "\nOpen in " + root.calendarProviderLabel
                  fontFamily: root.fontFamily
                }
              }

              Rectangle {
                anchors.centerIn: parent
                visible: modelData.is_today
                width: dayName.implicitWidth + Style.space(12)
                height: dayName.implicitHeight + Style.space(3)
                radius: height / 2
                color: Color.accent
              }

              Text {
                textFormat: Text.PlainText
                id: dayName
                anchors.centerIn: parent
                text: modelData.short_label
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: modelData.is_today ? Color.background : root.foreground
                opacity: modelData.is_today ? 1 : 0.6
              }
            }
          }
        }

        // All-day events do not belong on the time axis: they last the whole
        // day and would overshadow everything. Google puts them in their own
        // strip at the top for the same reason.
        Row {
          id: alldayRow
          width: parent.width
          height: visible ? implicitHeight : 0
          visible: root.alldayRows > 0 && root.reachable

          Item { width: root.gutter; height: 1 }

          Repeater {
            model: root.days

            Item {
              id: alldayColumn
              required property var modelData
              width: root.columnWidth
              height: root.alldayRows * root.alldayHeight

              Column {
                anchors.fill: parent
                anchors.rightMargin: root.weekView ? Style.space(2) : 0
                spacing: Style.space(2)

                Repeater {
                  model: alldayColumn.modelData.allday

                  // The same shape as the blocks in the column: the full
                  // calendar colour as the edge, a tinted fill. Without that
                  // edge they are almost grey and you cannot tell which
                  // calendar they belong to.
                  Rectangle {
                    id: allDayBlock
                    required property var modelData
                    width: parent.width
                    height: root.alldayHeight - Style.space(2)
                    radius: 0
                    readonly property color tint: Qt.lighter(modelData.color, 1.25)
                    color: Qt.rgba(tint.r, tint.g, tint.b, 0.24)
                    border.color: Color.accent
                    border.width: root.sameEvent(root.cursorEvent, modelData) ? 1 : 0

                    Rectangle {
                      anchors.left: parent.left
                      anchors.top: parent.top
                      anchors.bottom: parent.bottom
                      width: Style.space(3)
                      radius: 0
                      color: allDayBlock.modelData.color
                    }

                    MouseArea {
                      id: allDayMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.cursor = root.firstEventIndex + root.ring.indexOf(allDayBlock.modelData)
                        root.openEvent(allDayBlock.modelData)
                      }

                      PanelToolTip {
                        visible: allDayMouse.containsMouse
                        text: allDayBlock.modelData.title + "\nAll day \u00b7 " + allDayBlock.modelData.calendar
                        fontFamily: root.fontFamily
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(6)
                      text: allDayBlock.modelData.title
                      elide: Text.ElideRight
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.foreground
                      opacity: 0.85
                    }
                  }
                }
              }
            }
          }
        }

        // The time axis, with one column per day on it.
        Item {
          id: timeline
          width: parent.width
          // A strip below the axis, so the last hour label sits on it entirely
          // instead of half over the edge.
          readonly property real spanHeight: root.daySpan / 60 * root.hourHeight
          height: spanHeight + Style.space(10)
          visible: root.reachable

          function yFor(minutes) {
            return (minutes - root.dayStart) / root.daySpan * spanHeight
          }

          // Hour lines with their label. Whole hours only, within the visible
          // span: half hours make it unreadable at this height.
          Repeater {
            model: Math.floor(root.dayEnd / 60) - Math.ceil(root.dayStart / 60) + 1

            Item {
              required property int index
              readonly property int hour: Math.ceil(root.dayStart / 60) + index

              width: timeline.width
              height: 1
              y: timeline.yFor(hour * 60)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                width: root.gutter - Style.space(6)
                horizontalAlignment: Text.AlignRight
                // Gives way to the clock: two times on top of each other read
                // as neither.
                visible: Math.abs(root.nowMinutes - hour * 60) * root.hourHeight / 60 > Style.space(9)
                text: String(hour).padStart(2, "0") + ":00"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
                opacity: 0.4
              }

              Rectangle {
                anchors.left: parent.left
                anchors.leftMargin: root.gutter
                anchors.right: parent.right
                height: 1
                color: root.foreground
                opacity: 0.12
              }
            }
          }

          Row {
            x: root.gutter
            width: timeline.width - root.gutter
            height: timeline.spanHeight

            Repeater {
              model: root.days

              Item {
                id: dayColumn
                required property var modelData
                required property int index
                width: root.columnWidth
                height: timeline.spanHeight

                // The gap between two appointments, as soon as you put the
                // mouse in it. An empty spot in a calendar is information: the
                // question is never whether there is room but how much, and
                // working that out along the axis is exactly the job a calendar
                // ought
                // to be doing for you. Only between two appointments: at either
                // end of the day it is not a gap but an open end.
                MouseArea {
                  id: gapArea
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton

                  // Bound to mouseY rather than to a movement signal: the
                  // latter only fires once you move the mouse, so a panel that
                  // opened while you were already resting over a gap showed
                  // nothing until you moved again.
                  readonly property real atMinutes: containsMouse
                    ? root.dayStart + (mouseY / timeline.spanHeight) * root.daySpan
                    : -1

                  readonly property var previous: {
                    if (atMinutes < 0) return null
                    var best = null
                    var events = dayColumn.modelData.events
                    for (var i = 0; i < events.length; i++) {
                      var e = events[i]
                      if (e.end_minutes <= atMinutes && (!best || e.end_minutes > best.end_minutes))
                        best = e
                    }
                    return best
                  }

                  readonly property var next: {
                    if (atMinutes < 0) return null
                    var best = null
                    var events = dayColumn.modelData.events
                    for (var i = 0; i < events.length; i++) {
                      var e = events[i]
                      if (e.start_minutes >= atMinutes && (!best || e.start_minutes < best.start_minutes))
                        best = e
                    }
                    return best
                  }

                  // Waar het gat begint is niet de eindtijd van de vorige
                  // afspraak maar de onderkant van het blok dat je ziet: een kort
                  // overleg wordt hoger getekend dan het duurt, zodat de titel
                  // erop past, en de arcering liep daar anders dwars onderdoor.
                  readonly property real drawnBottom: {
                    if (!previous) return 0
                    var top = timeline.yFor(previous.start_minutes)
                    var span = timeline.yFor(previous.end_minutes) - top
                    return top + Math.max(Style.space(14), span - 2)
                  }

                  // Loopt het gat op dit moment, dan is de vraag niet hoe groot
                  // het is maar hoeveel je er nog van hebt: de tijd voor de
                  // nu-lijn is op. De arcering begint dan ook daar, want anders
                  // beslaat het vlak twee uur terwijl het label er een noemt.
                  readonly property bool nowInside:
                    dayColumn.modelData.is_today && previous !== null && next !== null
                    && root.nowMinutes > previous.end_minutes
                    && root.nowMinutes < next.start_minutes

                  readonly property int startMinutes:
                    nowInside ? root.nowMinutes : (previous ? previous.end_minutes : 0)

                  readonly property real gapTop: {
                    if (!previous) return 0
                    var edge = Math.max(timeline.yFor(previous.end_minutes), drawnBottom)
                    return nowInside ? Math.max(edge, timeline.yFor(root.nowMinutes)) : edge
                  }
                  readonly property real gapBottom: next ? timeline.yFor(next.start_minutes) : 0

                  // Wat er na dat opschuiven overblijft kan nul of minder zijn:
                  // twee korte afspraken vlak na elkaar laten visueel geen gat,
                  // en dan is er ook niets te arceren.
                  readonly property bool inGap: !root.detailEvent
                                                && previous !== null && next !== null
                                                && gapBottom - gapTop > Style.space(3)
                  readonly property int gapMinutes: inGap ? next.start_minutes - startMinutes : 0

                  Item {
                    id: gapVisual
                    // You may watch it appear, but after that it holds still:
                    // something that keeps moving while you read the rest of
                    // your week takes the attention you meant for the week.
                    opacity: gapArea.inGap ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity {
                      NumberAnimation { duration: 140; easing.type: Easing.OutQuad }
                    }
                    x: 0
                    y: gapArea.gapTop
                    width: dayColumn.width
                    height: gapArea.gapBottom - gapArea.gapTop

                    // Hatching across the whole gap. Diagonal and not
                    // horizontal: horizontal lines in a calendar read as time
                    // boundaries, and this is the opposite of a boundary.
                    // Rotated strokes behind a clip, because QML has no hatch
                    // pattern of its own.
                    Item {
                      id: hatch
                      anchors.fill: parent
                      clip: true

                      readonly property real pitch: Style.space(8)

                      // The hatching slides half a step into place while the
                      // area fades in, and then holds. A step is the period of
                      // the pattern, so half of one is enough to show the
                      // direction without anything appearing to jump.
                      property real shift: 0
                      NumberAnimation {
                        id: hatchIntro
                        target: hatch
                        property: "shift"
                        from: -hatch.pitch / 2
                        to: 0
                        duration: 260
                        easing.type: Easing.OutCubic
                      }

                      Connections {
                        target: gapArea
                        function onInGapChanged() { if (gapArea.inGap) hatchIntro.restart() }
                      }

                      Repeater {
                        // At 45 degrees a stroke starting at x runs off half a
                        // height to the left and to the right. To reach the
                        // bottom right corner as well, the starting points have
                        // to carry on past the right edge rather than stop at
                        // it: that is exactly where strokes went missing.
                        model: Math.ceil((hatch.width + hatch.height * 2) / hatch.pitch) + 2

                        Rectangle {
                          required property int index
                          width: 1
                          // Comfortably longer than the area: a stroke that
                          // rotates about its middle sticks out both ways.
                          height: (hatch.width + hatch.height) * 1.5
                          x: -hatch.height + index * hatch.pitch + hatch.shift
                          y: (hatch.height - height) / 2
                          rotation: 45
                          color: root.foreground
                          opacity: 0.14
                        }
                      }
                    }

                    // How much room there is, in the middle of the gap. A gap
                    // gets shorter than its own label long before it gets
                    // uninteresting, so the label gives way in steps: the word
                    // "free" goes first, the duration second, and what is left
                    // is the hatching, which already says the space is empty.
                    Text {
                      id: gapLabel
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      // Both directions matter: seven day columns are narrow,
                      // and a short gap is only a few pixels tall.
                      width: Math.min(implicitWidth, parent.width - Style.space(6))
                      visible: parent.height > implicitHeight + Style.space(4)
                               && parent.width > Style.space(30)
                      text: parent.height > implicitHeight * 2
                              ? root.spanLabel(gapArea.gapMinutes) + " free"
                              : root.spanLabel(gapArea.gapMinutes)
                      horizontalAlignment: Text.AlignHCenter
                      elide: Text.ElideRight
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.foreground
                      opacity: 0.7
                    }
                  }
                }

                // Today gets a lane of its own, so you can pick it out of a
                // week without reading the day names first.
                Rectangle {
                  anchors.fill: parent
                  visible: root.weekView && dayColumn.modelData.is_today
                  color: Color.accent
                  // Enough to find the column, not so much that the
                  // appointments in it look like a different colour from the
                  // same appointment on another day.
                  opacity: 0.05
                }

                // Edges left and right, so today's column has a beginning and
                // an end rather than only a tint.
                Repeater {
                  model: (root.weekView && dayColumn.modelData.is_today) ? 2 : 0

                  Rectangle {
                    required property int index
                    x: index === 0 ? 0 : dayColumn.width - width
                    width: 1
                    height: dayColumn.height
                    color: Color.accent
                    opacity: 0.5
                  }
                }

                // The divider between days. Without a line two full days run
                // into each other visually.
                Rectangle {
                  visible: root.weekView && dayColumn.index > 0
                  width: 1
                  height: parent.height
                  color: root.foreground
                  opacity: 0.12
                }

                Rectangle {
                  visible: dayColumn.modelData.is_today
                           && root.nowMinutes >= root.dayStart && root.nowMinutes <= root.dayEnd
                  y: timeline.yFor(root.nowMinutes) - 1
                  width: dayColumn.width
                  height: 2
                  color: root.urgentFill
                  z: 11
                }

                Repeater {
                  model: dayColumn.modelData.events

                  Rectangle {
                    id: block
                    required property var modelData

                    readonly property bool today: dayColumn.modelData.is_today
                    readonly property bool isNow: today
                                                  && root.nowMinutes >= modelData.start_minutes
                                                  && root.nowMinutes < modelData.end_minutes
                    readonly property bool isPast: today && root.nowMinutes >= modelData.end_minutes

                    // Overlapping appointments sit side by side; the script
                    // works out the columns. They all get the same width, which
                    // reads most calmly when a long appointment has short
                    // meetings next to it.
                    readonly property int lane: modelData.columns > 0 ? modelData.columns : 1
                    readonly property int inset: root.weekView ? Style.space(2) : Style.space(4)
                    readonly property real laneWidth: (dayColumn.width - inset) / lane

                    x: inset + modelData.column * laneWidth
                    width: laneWidth - (lane > 1 ? Style.space(2) : 0)
                    y: timeline.yFor(modelData.start_minutes)
                    // A short meeting must not shrink to a sliver, so there is
                    // a floor at which the title still fits.
                    height: Math.max(Style.space(14),
                                     timeline.yFor(modelData.end_minutes) - timeline.yFor(modelData.start_minutes) - 2)
                    radius: 0
                    // A lighter variant of the calendar colour as the fill:
                    // the full colour is already in the edge, and a block of it
                    // makes the title on top unreadable. Lightened rather than
                    // merely made transparent, because transparent on a dark
                    // background gives you grey instead of colour.
                    readonly property color tint: Qt.lighter(modelData.color, 1.25)
                    color: Qt.rgba(tint.r, tint.g, tint.b, isNow ? 0.5 : 0.28)
                    opacity: isPast ? 0.4 : 1
                    border.width: root.sameEvent(root.cursorEvent, modelData) ? 1 : 0
                    border.color: Color.accent

                    Rectangle {
                      anchors.left: parent.left
                      anchors.top: parent.top
                      anchors.bottom: parent.bottom
                      width: Style.space(3)
                      radius: 0
                      color: block.modelData.color
                    }

                    // The block holding the cursor reports itself. Measuring
                    // happens only when the card opens: during layout mapToItem
                    // still returns zeroes.
                    readonly property bool isCursor: root.sameEvent(root.cursorEvent, modelData)
                    onIsCursorChanged: if (isCursor) root.cursorItem = block

                    MouseArea {
                      id: blockMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.cursor = root.firstEventIndex + root.ring.indexOf(block.modelData)
                        root.cursorItem = block
                        root.openEvent(block.modelData)
                      }

                      // The start and end time are not always in the block:
                      // with overlap there is no room, and a short block shows
                      // only the title. Hover fills that in.
                      PanelToolTip {
                        visible: blockMouse.containsMouse
                        text: block.modelData.start + " \u2013 " + block.modelData.end
                              + "\n" + block.modelData.title
                        fontFamily: root.fontFamily
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(4)
                      anchors.topMargin: Style.space(3)
                      anchors.bottomMargin: Style.space(3)
                      // In the week there is no room for the time beside it,
                      // and there you read it off the axis anyway.
                      text: (block.lane > 1 || root.weekView)
                            ? block.modelData.title
                            : block.modelData.start + "  " + block.modelData.title
                      elide: Text.ElideRight
                      wrapMode: block.height > Style.space(30) ? Text.Wrap : Text.NoWrap
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.foreground
                    }
                  }
                }
              }
            }
          }

          // Now. Deliberately on top of everything, because this is the line
          // your eye should reach first.
          Item {
            width: timeline.width
            height: 1
            y: timeline.yFor(root.nowMinutes)
            visible: root.nowMinutes >= root.dayStart && root.nowMinutes <= root.dayEnd
            z: 10

            // The clock on the left, in the place of the hour label it covers
            // anyway. That way you do not have to work the line back to a time.
            Rectangle {
              anchors.right: parent.left
              anchors.rightMargin: -root.gutter + Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              width: nowLabel.implicitWidth + Style.space(8)
              height: nowLabel.implicitHeight + Style.space(2)
              radius: Style.cornerRadius
              color: root.urgentFill

              Text {
                textFormat: Text.PlainText
                id: nowLabel
                anchors.centerIn: parent
                text: root.clockText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: Color.background
              }
            }

            Rectangle {
              anchors.left: parent.left
              anchors.leftMargin: root.gutter
              anchors.right: parent.right
              height: root.weekView ? 1 : 2
              y: root.weekView ? 0 : -1
              color: root.urgentFill
              opacity: root.weekView ? 0.35 : 1
            }
          }
        }

        // Which calendars take part. At the bottom with the other choices,
        // because it is something you set once and then leave alone.
        MultiSelect {
          id: calendarPicker
          // Zonder agenda valt er niets te kiezen, en een lege keuzelijst onder
          // een uitleg over inloggen leidt alleen maar af.
          visible: root.reachable
          width: parent.width
          height: root.reachable ? Style.spacing.controlHeight : 0
          label: "Calendars"
          showLabel: false
          triggerLabel: "Calendars"
          noSelectionText: "All calendars"
          emptyText: "No calendars found"
          options: root.calendars
          values: root.checkedCalendars
          hasCursor: root.onCalendarPicker
          fontFamily: root.fontFamily
          onChanged: function(values) { root.applyCalendars(values) }
        }

        // Glancing at someone else's calendar. At the bottom, because it is
        // the exception: nine times out of ten you want your own day.
        Toggle {
          id: borrowedToggle
          visible: root.hasBorrowed
          width: parent.width
          height: root.hasBorrowed ? Style.space(24) : 0
          label: "Show " + root.borrowedLabel
          checked: root.showBorrowed
          hasCursor: root.onBorrowedToggle
          foreground: root.foreground
          fontFamily: root.fontFamily
          titleSize: Style.font.caption
          // No frame: this switch is not in a settings list but at the edge of
          // a calendar, and a boxed control draws more attention there than it
          // deserves. The fill comes back as soon as the mouse or the cursor is
          // on it, so you can still tell where you are.
          property bool hot: false
          onHovered: function(isHovered) { hot = isHovered }
          color: (hot || hasCursor) ? Style.hoverFillFor(root.foreground, Color.accent)
                                    : "transparent"
          borderSpec: Border.flat("transparent", 0)
          onClicked: root.toggleBorrowed()
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.reachable && root.days.length > 0 && root.emptyDay
          text: root.showBorrowed ? "Nothing on " + root.borrowedLabel : "Nothing planned"
          horizontalAlignment: Text.AlignHCenter
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          color: root.foreground
          opacity: 0.6
        }

        // Een agenda die niets kan laten zien hoort te vertellen wat eraan
        // scheelt. "Calendar unreachable" is waar en volstrekt nutteloos: het
        // verschil tussen niets geinstalleerd en niet ingelegd bepaalt wat je
        // nu moet doen, dus dat verschil staat er.
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: !root.reachable

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.blockedTitle
            horizontalAlignment: Text.AlignHCenter
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.foreground
            opacity: 0.85
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.blockedHint
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.6
          }

          // Niet iedereen wil een handleiding lezen om een bar-widget aan de
          // praat te krijgen. Deze knop legt de opdracht op je klembord, klaar
          // om aan een agent te geven die het voor je uitvoert.
          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.copiedPrompt ? "Copied, paste it to your agent" : "Copy setup instructions"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.copySetupPrompt()
          }
        }
      }

      // The expanded appointment, as a card over the grid. Not a real popup: a
      // PopupWindow never gets keyboard focus on Wayland, and then half of this
      // panel is out of reach. This is a layer in the same window, so the ring
      // keeps working.
      MouseArea {
        id: detailShade
        anchors.fill: parent
        z: 20
        visible: !!root.detailEvent
        // Catches the hover as well as the click. Otherwise the tooltips of
        // the blocks underneath keep coming up and sit over the card, which is
        // lying on that very block. One layer that catches everything beats
        // remembering at each separate tooltip that the card is open.
        hoverEnabled: true
        // A click beside the card does what Escape does.
        onClicked: root.closeDetail()

        Rectangle {
          id: detailCard
          readonly property real margin: Style.space(10)
          readonly property real desired: Style.space(360)

          width: Math.min(desired, parent.width - margin * 2)
          height: detailColumn.implicitHeight + Style.space(24)

          // Pinned to the block, but always fully in view: on the last day of
          // the week it would otherwise hang half outside the panel.
          x: Math.max(margin, Math.min(root.detailAnchorX, parent.width - width - margin))
          y: {
            var below = root.detailAnchorY + root.detailAnchorHeight + Style.space(6)
            if (below + height <= parent.height - margin) return below
            var above = root.detailAnchorY - height - Style.space(6)
            if (above >= margin) return above
            return Math.max(margin, parent.height - height - margin)
          }

          color: Color.popups ? Color.popups.background : Color.background
          radius: Style.cornerRadius
          border.width: Style.normalBorderWidth
          border.color: root.detailEvent ? root.detailEvent.color : root.foreground

          // The card catches its own clicks, or it would close the moment you
          // touched it.
          MouseArea { anchors.fill: parent }

          Column {
            id: detailColumn
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(10)

          Row {
            width: parent.width
            spacing: Style.space(8)

            Rectangle {
              width: Style.space(3)
              height: detailTitle.implicitHeight
              radius: width / 2
              color: root.detailEvent ? root.detailEvent.color : root.foreground
            }

            Text {
              textFormat: Text.PlainText
              id: detailTitle
              width: parent.width - Style.space(11)
              text: root.detailEvent ? root.detailEvent.title : ""
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              color: root.foreground
              wrapMode: Text.WordWrap
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.detailCalendar !== ""
                    ? root.detailWhen + "  \u00b7  " + root.detailCalendar
                    : root.detailWhen
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.75
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: text !== ""
            text: root.detailEvent ? String(root.detailEvent.location || "") : ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.75
            wrapMode: Text.WordWrap
          }

          // Attendees, with who has and has not answered. Without that state a
          // list of names is only a list of names.
          Column {
            width: parent.width
            spacing: Style.space(3)
            visible: root.detailAttendees.length > 0 || root.loadingAttendees

            Text {
              textFormat: Text.PlainText
              text: root.loadingAttendees && root.detailAttendees.length === 0
                      ? "Loading attendees"
                      : root.detailAttendees.length + " attendees"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.foreground
              opacity: 0.5
            }

            Repeater {
              model: root.detailAttendees
              delegate: Row {
                width: detailColumn.width
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: root.statusMark(modelData.status)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.statusColor(modelData.status)
                  opacity: 0.9
                }

                Text {
                  textFormat: Text.PlainText
                  text: String(modelData.name || "")
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.foreground
                  opacity: modelData.status === "declined" ? 0.45 : 0.85
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: text !== ""
            text: root.detailEvent ? String(root.detailEvent.description || "") : ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.7
            wrapMode: Text.WordWrap
            maximumLineCount: 8
            elide: Text.ElideRight
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.detailActions.length > 0

            Repeater {
              model: root.detailActions
              delegate: Button {
                text: modelData.label
                hasCursor: root.cursor === index
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.openUrl(modelData.url)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Esc goes back to the grid"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.4
          }
          }
        }
      }

    }
  }
}
