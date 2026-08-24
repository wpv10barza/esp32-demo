function doGet() {
  const now = new Date();
  const horizon = new Date(now.getTime() + 90 * 24 * 60 * 60 * 1000);
  const cal = CalendarApp.getDefaultCalendar();

  // Get future timed events and pick the first one that has not started yet.
  const events = cal.getEvents(now, horizon)
    .filter(e => !e.isAllDayEvent() && e.getStartTime().getTime() > now.getTime())
    .sort((a, b) => a.getStartTime().getTime() - b.getStartTime().getTime());

  if (events.length === 0) {
    return ContentService.createTextOutput('NONE\n' + Math.floor(now.getTime() / 1000))
      .setMimeType(ContentService.MimeType.TEXT);
  }

  const e = events[0];
  const timezone = Session.getScriptTimeZone();
  const title = (e.getTitle() || 'Untitled meeting')
    .replace(/[\r\n]+/g, ' ')
    .trim();
  const startText = Utilities.formatDate(e.getStartTime(), timezone, 'EEE, MMM d · h:mm a');

  const payload = [
    'OK',
    Math.floor(now.getTime() / 1000),
    Math.floor(e.getStartTime().getTime() / 1000),
    title,
    startText
  ].join('\n');

  return ContentService.createTextOutput(payload)
    .setMimeType(ContentService.MimeType.TEXT);
}
