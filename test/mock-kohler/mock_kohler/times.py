"""Timestamp forms the service mixes: UTC with an offset or Z, seven-digit fractions, naive local."""

from datetime import datetime, timedelta, timezone

FORMAT = "%Y-%m-%dT%H:%M:%S"


def _utc(t):
    return datetime.fromtimestamp(t, timezone.utc)


def utc_iso(t, fraction=False, z=False):
    """UTC with +00:00 (or Z); fraction adds seven fractional digits."""
    if t is None:
        return None
    text = _utc(int(t)).strftime(FORMAT)
    if fraction:
        text += f".{min(int((t % 1) * 10_000_000), 9_999_999):07d}"
    return text + ("Z" if z else "+00:00")


def local_naive(t, offset_hours):
    """Local wall time at the generator with no offset."""
    if t is None:
        return None
    return _utc(int(t) + offset_hours * 3600).strftime(FORMAT)


def parse(text, offset_hours):
    """Epoch seconds from any of the forms; a naive value is local at the generator."""
    dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone(timedelta(hours=offset_hours)))
    return dt.timestamp()


def add_month(t, offset_hours):
    """The same local wall time one calendar month on, clamped to the month's last day."""
    tz = timezone(timedelta(hours=offset_hours))
    dt = datetime.fromtimestamp(t, tz)
    year, month = (dt.year + 1, 1) if dt.month == 12 else (dt.year, dt.month + 1)
    for day in (dt.day, 30, 29, 28):
        try:
            return dt.replace(year=year, month=month, day=day).timestamp()
        except ValueError:
            continue
    raise ValueError("no valid day")


def next_weekly(now, offset_hours, weekday, hhmm):
    """The next local weekday (Monday 0) at HH:MM strictly after now."""
    tz = timezone(timedelta(hours=offset_hours))
    hour, minute = (int(x) for x in hhmm.split(":"))
    local = datetime.fromtimestamp(now, tz)
    cand = local.replace(hour=hour, minute=minute, second=0, microsecond=0)
    cand += timedelta(days=(weekday - local.weekday()) % 7)
    if cand.timestamp() <= now:
        cand += timedelta(days=7)
    return cand.timestamp()
