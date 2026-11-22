# Meetings can be named after their calendar event, optionally

2.x titles a Meeting from the Notes backend, or from its date without one, which says little in the meeting list. An optional setting, "Name Meetings after calendar events", reads the user's calendar once at Stop (and when an Interrupted meeting is recovered) and stores the matching event's title as the Meeting's title, which wins over the Notes title the way a Rename does. With the setting off, no access or no match, everything works as before.

The matcher (`CalendarEvent.title(for:in:)`, OatsCore, unit-tested) takes the whole recording, not its start:

- Only events with other attendees or a call link count. Personal blocks ("Focus", "Lunch") never name a Meeting, which is what made 1.x pick the wrong event (#701).
- The event overlapping the recording most wins; the shorter one on a tie, so a meeting inside an all-hands or offsite block wins over the block.
- The overlap must be at least a quarter of the shorter of the two, so a recording that started in the tail of the previous meeting isn't named after it (#706), and a call right after a meeting isn't either.
- All-day, cancelled and declined events are left out.

## Asking for access

Calendar access is asked for only when the user turns the setting on: from Settings › General, the optional Calendar row in onboarding, or a one-line "Name Meetings after your calendar events?" tip on a finished Meeting. The tip shows until the user answers it once (`titleFromCalendar` is nil until then); declining the system prompt counts as "no". 1.x prompted from views appearing and timers, and showed stale "Waiting for calendar access" banners from cached state (#517, #671, #711); 2.x re-reads the authorization status each time it's shown or used and never prompts on its own.

## Considered Options

- Window or tab titles (Accessibility, AppleScript): rejected; app-specific, more permissions, and Zoom's window only says "Zoom Meeting".
- 1.x's upcoming-meetings dashboard, per-calendar filters, meeting families, attendee names and calendar context for Notes: left out; each added state and bugs for little gain in naming a Meeting.

## Consequences

The main app carries `NSCalendarsFullAccessUsageDescription` and the hardened-runtime `com.apple.security.personal-information.calendars` entitlement; the `oats` child never reads the calendar. Imported audio and `oats record` aren't named from the calendar. Meetings recorded before the setting was on keep their titles.
