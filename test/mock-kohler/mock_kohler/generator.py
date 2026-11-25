"""One simulated generator: its state machine and its record as the service reports it."""

import copy
import heapq
import itertools

from . import times

RUNNING_STATES = {
    "CrankOn",
    "Running",
    "CoolDown",
    "PerformingUnloadedExercise",
    "PerformingUnloadedFullSpeedExercise",
    "PerformingLoadedExercise",
    "PerformingVariableSpeedExercise",
}
EXERCISE_STATES = {
    "Unloaded": "PerformingUnloadedExercise",
    "UnloadedFullSpeed": "PerformingUnloadedFullSpeedExercise",
    "LoadedFullSpeed": "PerformingLoadedExercise",
    "EcoExercise": "PerformingVariableSpeedExercise",
}
LOADED_MODES = {"LoadedFullSpeed"}
FREQUENCY_DAYS = {"Weekly": 7, "EveryOtherWeek": 14, "Monthly": None}
SWITCH_STATES = ("Off", "Auto", "Manual")
DISPLAY = {
    "Standby": "Standby",
    "Off": "Off",
    "CrankOn": "Crank On",
    "Running": "Running",
    "CoolDown": "Cool Down",
    "Shutdown": "Shutdown",
    "PerformingUnloadedExercise": "Performing Unloaded Exercise",
    "PerformingUnloadedFullSpeedExercise": "Performing Unloaded Full Speed Exercise",
    "PerformingLoadedExercise": "Performing Loaded Exercise",
    "PerformingVariableSpeedExercise": "Performing Variable Speed Exercise",
}
DEFAULT_TIMING = {
    "crank_s": 5,
    "transfer_s": 3,
    "start_delay_s": 3,
    "retransfer_s": 60,
    "cooldown_s": 120,
}
DURATION_RANGE = (5, 60)
LOW_BATTERY_EVENT = "Low Battery Voltage"


class Refused(Exception):
    """A request the service turns down, with its HTTP status."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


class Ids:
    """Id sequences shared by every generator in one cloud."""

    def __init__(self):
        self.events = itertools.count(10_000_000_101)
        self.alerts = itertools.count(20_001)
        self.notices = itertools.count(30_000_001)


def reverse_mac(mac):
    return ":".join(reversed(mac.upper().split(":")))


class Generator:
    def __init__(self, spec, profile, home, owner, clock, ids):
        self.spec = spec
        self.profile = profile
        self.home = home
        self.owner = owner
        self.clock = clock
        self.ids = ids
        self.id = int(spec["id"])
        self.serial = spec["serialNumber"]
        self.name = spec.get("displayName", "Demo Generator")
        self.mac = spec.get("macAddress", "02:00:00:00:00:01")
        self.ip = spec.get("deviceIpAddress", "192.0.2.10:2402")
        self.tz = profile.get("utcOffsetHours", 0)
        quirks = profile.get("quirks", {})
        self.naive = quirks.get("naiveLocalTimes", False)
        self.negative_load = quirks.get("negativeLoad", False)
        self.fraction = quirks.get("fractionalSeconds", False)
        self.timing = {**DEFAULT_TIMING, **profile.get("timing", {})}
        self.modes = profile.get("exerciseModes", list(EXERCISE_STATES))

        now = clock.now()
        self.t = now
        self.queue = []
        self.seq = itertools.count()
        self.switch = profile.get("switchState", "Auto")
        self.engine = "Off" if self.switch == "Off" else "Standby"
        self.utility = True
        self.power = "Utility"
        self.kind = None
        self.ex_mode = None
        self.fault = None
        self.battery_low = False
        self.run_start = None
        self.status_t = now - 3600
        self.param_t = now - 600
        self.alerts = []
        self.events = []
        self.notifications = []
        self.pending_events = []
        self.pending_notices = []

        hours = profile.get("hours", {})
        self.runtime = float(hours.get("totalRuntimeHours", 0.0))
        self.operation = float(hours.get("totalOperationHours", 0.0))
        self.since_maint = float(hours.get("runtimeSinceLastMaintenanceHours", 0.0))
        maint = profile.get("maintenance", {"periodDays": 365, "lastDaysAgo": 90})
        self.maint_period = maint["periodDays"]
        self.maint_last = now - maint["lastDaysAgo"] * 86400

        self.schedule = None
        self.ex_last_start = self.ex_last_end = self.last_ran = None
        ex = profile.get("exercise")
        if ex:
            nxt = times.next_weekly(now, self.tz, ex.get("weekday", 5), ex.get("time", "10:00"))
            self.schedule = {
                "frequency": ex["frequency"],
                "mode": ex["mode"],
                "durationMinutes": ex["durationMinutes"],
                "next": nxt,
            }
            self.ex_last_start = nxt - (FREQUENCY_DAYS[ex["frequency"]] or 30) * 86400
            self.ex_last_end = self.ex_last_start + ex["durationMinutes"] * 60
            self.last_ran = self.ex_last_start

        self.load_shed = copy.deepcopy(profile.get("loadShed"))
        self.pim = copy.deepcopy(profile.get("pim"))

        self.started = False
        self.online = True
        self.offline_since = None
        self.snapshot = None
        self.snapshot_alerts = None
        self.not_connected_id = -(1_000_000_000 + self.id)
        if profile.get("startsOffline"):
            self.status_t = now - 3 * 86400
            self.set_online(False, at=now - 3 * 86400)

    # ─── Time ─────────────────────────────────────────────────────────────

    def _after(self, seconds, action, *args):
        heapq.heappush(self.queue, (self.t + seconds, next(self.seq), action, args))

    def _cancel(self, *actions):
        self.queue = [q for q in self.queue if q[2] not in actions]
        heapq.heapify(self.queue)

    def _cancel_all(self):
        self.queue = []

    def _move(self, t):
        dt = t - self.t
        if dt <= 0:
            return
        hours = dt / 3600.0
        self.operation += hours
        if self.engine in RUNNING_STATES:
            self.runtime += hours
            self.since_maint += hours
        self.t = t

    def _next_due(self):
        due = []
        if self.queue:
            due.append((self.queue[0][0], 0))
        if self.schedule and self.schedule.get("next") is not None:
            due.append((self.schedule["next"], 1))
        return min(due) if due else None

    def settle(self, now=None):
        """Run every transition due up to now, in time order."""
        now = self.clock.now() if now is None else now
        while True:
            due = self._next_due()
            if due is None or due[0] > now:
                break
            self._move(due[0])
            if due[1] == 0:
                _, _, action, args = heapq.heappop(self.queue)
                getattr(self, f"_on_{action}")(*args)
            else:
                self._scheduled_exercise()
        self._move(now)

    def _touch(self):
        self.status_t = self.t

    # ─── Log ──────────────────────────────────────────────────────────────

    def _event(self, event, level="Status", etype="notice", critical=False):
        rec = {
            "id": next(self.ids.events),
            "name": f"{event} {level}",
            "level": level,
            "event": event,
            "fmi": "NotApplicable",
            "parameterId": None,
            "parameter": None,
            "timestamp": times.utc_iso(self.t),
            "type": etype,
            "isCriticalFault": critical,
        }
        (self.events if self.online else self.pending_events).append(rec)

    def _notice(self, ntype, message):
        rec = {
            "id": next(self.ids.notices),
            "tag": f"homeowneruser:{self.owner.id}",
            "type": ntype,
            "message": message,
            "timestamp": times.utc_iso(self.t, fraction=True),
            "deviceId": self.id,
            "serialNumber": self.serial,
            "displayName": self.name,
        }
        (self.notifications if self.online else self.pending_notices).append(rec)

    def _alert(self, event, level, critical):
        rec = {
            "canRemoteResetFault": False if critical else None,
            "event": event,
            "fmi": "NotApplicable",
            "id": next(self.ids.alerts),
            "isCriticalFault": critical,
            "level": level,
            "name": f"{event} {level}",
            "parameter": None,
            "parameterId": None,
            "timestamp": times.utc_iso(self.t),
            "type": level.lower(),
        }
        self.alerts.append(rec)
        return rec

    # ─── Engine ───────────────────────────────────────────────────────────

    def _wants_generator_power(self):
        if self.kind == "exercise":
            return self.ex_mode in LOADED_MODES
        return self.kind in ("outage", "manual") and not self.utility

    def _crank(self):
        self.engine = "CrankOn"
        self.run_start = self.t
        self.started = False
        self._after(self.timing["crank_s"], "started")
        self._touch()

    def _on_started(self):
        if self.engine != "CrankOn":
            return
        self.engine = EXERCISE_STATES[self.ex_mode] if self.kind == "exercise" else "Running"
        self.started = True
        self._event("Engine Started", etype="runningNotice")
        self._notice(
            "EngineStartedNotice", f'The engine on your generator "{self.name}" has started.'
        )
        if self._wants_generator_power():
            self._after(self.timing["transfer_s"], "transfer")
        elif self.kind == "outage" and self.utility:
            self.kind = None
            self._cool()
        self._touch()

    def _on_transfer(self):
        if self.engine in RUNNING_STATES and self._wants_generator_power():
            self.power = "Generator"
            self._touch()

    def _cool(self):
        self._cancel("started", "transfer", "stopped")
        self.engine = "CoolDown"
        self._after(self.timing["cooldown_s"], "stopped")
        self._touch()

    def _on_stopped(self):
        if self.engine == "CoolDown":
            self._stop_engine()

    def _stop_engine(self):
        was_running = self.started
        self.started = False
        self.engine = "Off" if self.switch == "Off" else "Standby"
        self.power = "Utility"
        if was_running:
            self._event("Engine Stopped")
            self._notice(
                "EngineStoppedNotice", f'The engine on your generator "{self.name}" has stopped.'
            )
            self.last_ran = self.run_start
        self.run_start = None
        self._touch()

    # ─── Exercise ─────────────────────────────────────────────────────────

    def _exercise_blocked(self):
        if self.fault:
            return "The generator is shut down by a fault"
        if self.switch != "Auto":
            return "The generator switch is not in Auto"
        if self.kind or self.engine in RUNNING_STATES:
            return "The generator is already running"
        return None

    def _start_exercise(self, mode, minutes):
        self.kind = "exercise"
        self.ex_mode = mode
        self.ex_last_start = self.t
        self._event("Exercise Active")
        self._notice(
            "ExerciseStartedNotice", f'An exercise has started on your generator "{self.name}".'
        )
        self._crank()
        self._after(minutes * 60, "exercise_end")

    def _end_exercise(self):
        self._cancel("exercise_end")
        self.kind = None
        self.ex_mode = None
        self.ex_last_end = self.t
        self._event("Exercise Ended")
        self._notice(
            "ExerciseEndedNotice", f'An exercise has ended on your generator "{self.name}".'
        )

    def _on_exercise_end(self):
        if self.kind != "exercise":
            return
        self._end_exercise()
        if self.utility:
            self.power = "Utility"
        self._cool()

    def _roll(self, t, frequency):
        days = FREQUENCY_DAYS.get(frequency)
        return times.add_month(t, self.tz) if days is None else t + days * 86400

    def _scheduled_exercise(self):
        s = self.schedule
        s["next"] = self._roll(s["next"], s["frequency"])
        if self._exercise_blocked() is None and self.utility:
            self._start_exercise(s["mode"], s["durationMinutes"])

    def run_scheduled_now(self):
        """The scheduled exercise, started now as the controller would start it."""
        self.settle()
        if not self.schedule:
            raise ValueError("no exercise is scheduled")
        reason = self._exercise_blocked()
        if reason:
            raise ValueError(reason)
        self._start_exercise(self.schedule["mode"], self.schedule["durationMinutes"])

    def start_exercise(self, mode):
        self.settle()
        if mode not in self.modes:
            raise Refused(400, f"Exercise mode {mode!r} is not supported by this generator")
        if not self.online:
            raise Refused(409, "The generator is offline")
        if not self.utility:
            raise Refused(409, "Utility power is out")
        if self.kind == "exercise":
            raise Refused(409, "An exercise is already running")
        status = self.status()
        if status != "ReadyToRun":
            raise Refused(409, f"The generator is not ready to run ({status})")
        minutes = (self.schedule or {}).get("durationMinutes") or 20
        self._start_exercise(mode, minutes)

    def stop_exercise(self):
        self.settle()
        if not self.online:
            raise Refused(409, "The generator is offline")
        if self.kind != "exercise":
            raise Refused(409, "No exercise is running")
        self._end_exercise()
        if self.utility:
            self.power = "Utility"
        self._cool()

    def set_schedule(self, body):
        self.settle()
        if not self.online:
            raise Refused(409, "The generator is offline")
        frequency, mode = body.get("frequency"), body.get("mode")
        minutes, start = body.get("durationMinutes"), body.get("nextStartTimestamp")
        if frequency not in FREQUENCY_DAYS:
            raise Refused(400, f"Invalid exercise frequency {frequency!r}")
        if mode not in self.modes:
            raise Refused(400, f"Exercise mode {mode!r} is not supported by this generator")
        lo, hi = DURATION_RANGE
        if not isinstance(minutes, int) or isinstance(minutes, bool) or not lo <= minutes <= hi:
            raise Refused(400, f"durationMinutes must be a whole number from {lo} to {hi}")
        try:
            nxt = times.parse(start, self.tz)
        except (TypeError, ValueError, AttributeError):
            raise Refused(400, "Invalid nextStartTimestamp") from None
        if nxt <= self.t:
            raise Refused(400, "nextStartTimestamp is in the past")
        self.schedule = {
            "frequency": frequency,
            "mode": mode,
            "durationMinutes": minutes,
            "next": nxt,
        }
        self._touch()

    def delete_schedule(self):
        self.settle()
        if not self.online:
            raise Refused(409, "The generator is offline")
        self.schedule = None
        self._touch()

    # ─── Utility ──────────────────────────────────────────────────────────

    def utility_lost(self):
        self.settle()
        if not self.utility:
            return
        self.utility = False
        self._event("Utility Power Lost")
        running = self.engine in RUNNING_STATES and self.engine != "CrankOn"
        if self.kind == "exercise":
            self._end_exercise()
            self.kind = "outage"
            if running:
                self.engine = "Running"
                self._after(self.timing["transfer_s"], "transfer")
        elif self.kind == "manual":
            if running:
                self._after(self.timing["transfer_s"], "transfer")
        elif self.engine == "CoolDown" and self.switch == "Auto" and not self.fault:
            self._cancel("stopped")
            self.kind = "outage"
            self.engine = "Running"
            self._after(self.timing["transfer_s"], "transfer")
        elif self._exercise_blocked() is None:
            self._after(self.timing["start_delay_s"], "outage_start")
        self._touch()

    def _on_outage_start(self):
        if not self.utility and self._exercise_blocked() is None:
            self.kind = "outage"
            self._crank()

    def utility_restored(self):
        self.settle()
        if self.utility:
            return
        self.utility = True
        self._event("Utility Power Restored")
        self._cancel("outage_start", "transfer")
        if self.power == "Generator" or self.kind == "outage":
            self._after(self.timing["retransfer_s"], "retransfer")
        self._touch()

    def _on_retransfer(self):
        if not self.utility:
            return
        self.power = "Utility"
        if self.kind == "outage" and self.engine != "CrankOn":
            self.kind = None
            self._cool()
        self._touch()

    # ─── Switch, faults, battery, connection ─────────────────────────────

    def set_switch(self, position):
        self.settle()
        if position not in SWITCH_STATES:
            raise ValueError(f"position must be one of {', '.join(SWITCH_STATES)}")
        if position == self.switch:
            return
        self.switch = position
        if position == "Off":
            if self.kind == "exercise":
                self._end_exercise()
            self._cancel_all()
            self.kind = None
            if self.engine in RUNNING_STATES:
                self._stop_engine()
            elif not self.fault:
                self.engine = "Off"
            self.power = "Utility"
        elif position == "Manual":
            self._cancel("outage_start", "stopped")
            if self.kind == "exercise":
                self._end_exercise()
                if self.utility:
                    self.power = "Utility"
            self.kind = "manual"
            if self.fault:
                pass
            elif self.engine in RUNNING_STATES and self.engine != "CrankOn":
                self.engine = "Running"
                if not self.utility:
                    self._after(self.timing["transfer_s"], "transfer")
            elif self.engine != "CrankOn":
                self._crank()
        else:
            if self.engine == "Off":
                self.engine = "Standby"
            if self.kind == "manual":
                if self.utility:
                    self.kind = None
                    self._cool()
                else:
                    self.kind = "outage"
            elif not self.utility and self._exercise_blocked() is None:
                self._after(self.timing["start_delay_s"], "outage_start")
        self._touch()

    def raise_fault(self, event="Overcrank"):
        self.settle()
        if self.kind == "exercise":
            self._end_exercise()
        self._cancel_all()
        self.kind = None
        if self.engine in RUNNING_STATES:
            self._stop_engine()
        self.engine = "Shutdown"
        self.power = "Utility"
        self.fault = self._alert(event, "Shutdown", critical=True)
        self._event(event, level="Shutdown", etype="shutdown", critical=True)
        self._notice(
            "Shutdown",
            f'Your generator "{self.name}" has shut down ({event}). '
            "Please contact your dealer or technician.",
        )
        self._touch()

    def raise_warning(self, event="Parameter Value Abnormal"):
        self.settle()
        self._alert(event, "Warning", critical=False)
        self._event(event, level="Warning", etype="warning")
        self._notice(
            "Warning",
            f'You have some warnings on your generator "{self.name}". '
            "Please review the activity log and contact your dealer or technician.",
        )
        self._touch()

    def clear_alerts(self):
        self.settle()
        self.alerts = []
        if self.fault:
            self.fault = None
            self.engine = "Off" if self.switch == "Off" else "Standby"
            if self.switch == "Manual":
                self._crank()
            elif self.switch == "Auto" and not self.utility:
                self._after(self.timing["start_delay_s"], "outage_start")
        self._touch()

    def set_battery(self, low):
        self.settle()
        if low == self.battery_low:
            return
        self.battery_low = low
        if low:
            self.raise_warning(LOW_BATTERY_EVENT)
        else:
            self.alerts = [a for a in self.alerts if a["event"] != LOW_BATTERY_EVENT]
            self._touch()

    def set_online(self, online, at=None):
        if at is None:
            self.settle()
        if online == self.online:
            return
        if not online:
            now, self.t = self.t, (self.t if at is None else at)
            self.snapshot = self._live()
            self.t = now
            self.snapshot_alerts = copy.deepcopy(self.alerts)
            self.offline_since = self.t if at is None else at
            self.online = False
        else:
            self.online = True
            self.snapshot = self.snapshot_alerts = None
            self.events += self.pending_events
            self.notifications += self.pending_notices
            self.pending_events, self.pending_notices = [], []
            self._touch()

    # ─── Peripherals ──────────────────────────────────────────────────────

    def _param(self, definition_id):
        for group_name in ("loadShed", "pim"):
            group = self.load_shed if group_name == "loadShed" else self.pim
            for p in (group or {}).get("parameters", []):
                if p["definitionId"] == definition_id:
                    return group_name, group, p
        raise Refused(404, "Parameter not found")

    def set_value(self, definition_id, value):
        self.settle()
        if not self.online:
            raise Refused(409, "The generator is offline")
        group_name, group, p = self._param(definition_id)
        if group_name == "pim" or p.get("isReadOnly"):
            raise Refused(400, "Parameter is read only")
        if not isinstance(value, bool):
            raise Refused(400, "value must be true or false")
        if not group.get("isConnected"):
            raise Refused(409, "The load management module is not connected")
        p["value"] = value
        self.param_t = self.t

    def rename(self, definition_id, name):
        self.settle()
        _, _, p = self._param(definition_id)
        if not isinstance(name, str) or not name.strip() or len(name) > 50:
            raise Refused(400, "displayName must be 1 to 50 characters")
        p["displayName"] = name.strip()

    # ─── Record ───────────────────────────────────────────────────────────

    def status(self):
        if not self.online:
            return "Offline"
        if self.fault:
            return "Shutdown"
        if self.switch == "Off":
            return "SwitchStateOff"
        if self.kind == "exercise":
            return "RunningExercise"
        if self.engine in RUNNING_STATES:
            return "Running"
        return "ReadyToRun"

    def _local_or_utc(self, t, z=False):
        return times.local_naive(t, self.tz) if self.naive else times.utc_iso(t, z=z)

    def _exercise(self):
        s = self.schedule
        return {
            "frequency": s["frequency"] if s else None,
            "nextStartTimestamp": self._local_or_utc(s["next"], z=True) if s else None,
            "mode": s["mode"] if s else "None",
            "runningMode": self.ex_mode if self.kind == "exercise" else None,
            "durationMinutes": s["durationMinutes"] if s else None,
            "lastStartTimestamp": times.utc_iso(self.ex_last_start),
            "lastEndTimestamp": times.utc_iso(self.ex_last_end),
        }

    def _device(self):
        p = self.profile
        return {
            "id": self.id,
            "serialNumber": self.serial,
            "displayName": self.name,
            "deviceHost": p.get("deviceHost", "Oncue"),
            "hasAcceptedPrivacyPolicy": True,
            "address": copy.deepcopy(self.home["address"]),
            "product": p["product"],
            "productDisplayName": p["productDisplayName"],
            "controllerType": p["controllerType"],
            "firmwareVersion": p["firmwareVersion"],
            "currentFirmware": p.get("currentFirmware"),
            "isConnected": True,
            "lastConnectedTimestamp": times.utc_iso(self.t - (self.t % 60)),
            "deviceIpAddress": self.ip,
            "macAddress": reverse_mac(self.mac),
            "status": self.status(),
            "statusUpdateTimestamp": times.utc_iso(self.status_t, fraction=self.fraction),
            "latestParameterUpdateTimestamp": times.utc_iso(self.param_t, fraction=self.fraction),
            "dealerOrgs": copy.deepcopy(p.get("dealerOrgs", [])),
            "alertCount": len(self.alerts),
            "model": p["model"],
            "modelDisplayName": p["modelDisplayName"],
            "lastMaintenanceTimestamp": self._local_or_utc(self.maint_last),
            "nextMaintenanceTimestamp": self._local_or_utc(
                self.maint_last + self.maint_period * 86400
            ),
            "maintenancePeriodDays": self.maint_period,
            "hasServiceAgreement": (p.get("serviceAgreement") or {}).get("hasServiceAgreement"),
            "totalRuntimeHours": round(self.runtime, 1),
        }

    def _live(self):
        p = self.profile
        tele = copy.deepcopy(p["telemetry"]["standby"])
        if self.engine in RUNNING_STATES and self.engine != "CrankOn":
            tele.update(p["telemetry"]["running"])
        if self.battery_low:
            tele["batteryVoltageV"] = p.get("lowBatteryVoltageV", 11.6)
        load = p.get("loadW", 0) if self.power == "Generator" else 0
        percent = round(load / (p["ratedKw"] * 1000) * 100) if load else 0
        if self.negative_load and load:
            load, percent = -load, -percent
        return {
            "device": self._device(),
            "powerSource": self.power,
            "switchState": self.switch,
            "coolingType": p["coolingType"],
            "connectionType": p.get("connectionType", "Ethernet"),
            "serverIpAddress": p.get("serverIpAddress", "198.51.100.20"),
            "serviceAgreement": copy.deepcopy(p.get("serviceAgreement")),
            "exercise": self._exercise(),
            "lastRanTimestamp": times.utc_iso(self.last_ran),
            "totalRuntimeHours": round(self.runtime, 1),
            "totalOperationHours": round(self.operation, 1),
            "runtimeSinceLastMaintenanceHours": round(self.since_maint, 1),
            "remoteResetCounterSeconds": p.get("remoteResetCounterSeconds"),
            "addedBy": None,
            "associatedUsers": [self.owner.email],
            "controllerClockTimestamp": times.local_naive(self.t, self.tz),
            "fuelType": p["fuelType"],
            **tele,
            "utilityVoltageV": p.get("utilityVoltageV", 240.0) if self.utility else 0,
            "generatorLoadW": load,
            "generatorLoadPercent": percent,
            "engineState": self.engine,
            "engineStateDisplayNameEn": DISPLAY.get(self.engine, self.engine),
            "loadShed": copy.deepcopy(self.load_shed),
            "pim": copy.deepcopy(self.pim),
        }

    def record(self):
        """The full record, as GET devices/{id} returns it."""
        if self.online:
            return self._live()
        rec = copy.deepcopy(self.snapshot)
        dev = rec["device"]
        dev["isConnected"] = False
        dev["status"] = "Offline"
        dev["lastConnectedTimestamp"] = times.utc_iso(self.offline_since)
        dev["alertCount"] = len(self.snapshot_alerts) + 1
        return rec

    def summary(self):
        """The device entry inside homeowner/homes."""
        dev = self.record()["device"]
        dev.pop("latestParameterUpdateTimestamp", None)
        return dev

    def alert_list(self):
        if self.online:
            return list(reversed(copy.deepcopy(self.alerts)))
        not_connected = {
            "canRemoteResetFault": None,
            "event": "Not Connected",
            "fmi": "NotApplicable",
            "id": self.not_connected_id,
            "isCriticalFault": False,
            "level": "None",
            "name": "Not Connected",
            "parameter": None,
            "parameterId": None,
            "timestamp": times.utc_iso(self.offline_since),
            "type": "notice",
        }
        return [not_connected] + list(reversed(copy.deepcopy(self.snapshot_alerts)))

    def event_list(self):
        return list(reversed(copy.deepcopy(self.events)))

    def state(self):
        """What /_mock/state shows for this generator."""
        return {
            "name": self.name,
            "account": self.owner.email,
            "online": self.online,
            "utility": self.utility,
            "switch": self.switch,
            "engine": self.engine,
            "kind": self.kind,
            "power": self.power,
            "fault": self.fault["event"] if self.fault else None,
            "battery_low": self.battery_low,
            "schedule_next": times.utc_iso(self.schedule["next"]) if self.schedule else None,
            "pending": [[round(q[0] - self.t, 1), q[2]] for q in sorted(self.queue)],
        }
