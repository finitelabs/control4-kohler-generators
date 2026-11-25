"""Time sources. Everything in the mock reads time from one of these, in epoch seconds."""

import time


class Clock:
    def now(self):
        return time.time()


class FakeClock:
    """A clock tests move by hand."""

    def __init__(self, start=1_790_000_000.0):
        self.t = float(start)

    def now(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds


class SimClock:
    """The generators' clock: runs `speed` times faster than its base and can jump ahead."""

    def __init__(self, base, speed=1.0):
        self.base = base
        self.speed = float(speed)
        self.start = base.now()
        self.offset = 0.0

    def now(self):
        return self.start + (self.base.now() - self.start) * self.speed + self.offset

    def advance(self, seconds):
        self.offset += float(seconds)
