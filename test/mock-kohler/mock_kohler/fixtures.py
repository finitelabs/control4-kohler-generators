"""Write the replies the driver's Lua tests read, from the demo and offline instances on a fixed clock,
and one generator's record, alerts and events in each state the driver reacts to.

python -m mock_kohler.fixtures OUT_DIR           write them
python -m mock_kohler.fixtures OUT_DIR --check   fail when the files differ from what the mock gives
"""

import argparse
import copy
import json
import sys
from pathlib import Path

from . import ROOT
from .clock import FakeClock
from .cloud import Cloud
from .generator import Ids

INSTANCES = ("demo", "offline")

SCENARIO_DEVICE = 58001

# Each state the driver reacts to: the steps that bring the demo's first generator to it.
SCENARIOS = {
    "standby": [],
    "outage": [("utility_lost",), ("wait", 30)],
    "restored": [("utility_lost",), ("wait", 30), ("utility_restored",), ("wait", 300)],
    "exercise": [("start_exercise", "Unloaded"), ("wait", 30)],
    "fault": [("raise_fault", "Overcrank")],
    "warning": [("raise_warning", "Parameter Value Abnormal")],
    "low-battery": [("set_battery", True)],
    "cleared": [("raise_warning", "Parameter Value Abnormal"), ("clear_alerts",)],
    "switch-off": [("set_switch", "Off")],
}


def scenario(steps, ids):
    """The demo's first generator after `steps`, on its own fixed clock. `ids` numbers its alerts
    and events after every scenario before it, as one generator's log would."""
    cfg = json.loads((ROOT / "instances" / "demo.json").read_text())
    clock = FakeClock()
    cloud = Cloud(cfg, clock=clock)
    cloud.settle()
    gen = cloud.generators[SCENARIO_DEVICE]
    gen.ids = ids
    for step in steps:
        if step[0] == "wait":
            clock.advance(step[1])
            cloud.settle()
        else:
            getattr(gen, step[0])(*step[1:])
    cloud.settle()
    return gen


def replies():
    """Each fixture's file name and its JSON."""
    out = {}
    for name in INSTANCES:
        cfg = json.loads((ROOT / "instances" / f"{name}.json").read_text())
        cloud = Cloud(cfg, clock=FakeClock())
        cloud.settle()
        acct = cloud.accounts[0]
        homes = []
        for home in acct.homes:
            entry = copy.deepcopy(home)
            entry["devices"] = [g.summary() for g in acct.generators if g.home is home]
            homes.append(entry)
        out[f"{name}-homes.json"] = homes
        for gen in acct.generators:
            out[f"device-{gen.id}.json"] = gen.record()
    ids = Ids()
    for name, steps in SCENARIOS.items():
        gen = scenario(steps, ids)
        out[f"state-{name}.json"] = gen.record()
        out[f"state-{name}-alerts.json"] = gen.alert_list()
        out[f"state-{name}-events.json"] = gen.event_list()
    return out


def render(value):
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("out", help="directory the fixtures go in")
    ap.add_argument("--check", action="store_true", help="compare instead of writing")
    args = ap.parse_args(argv)
    out = Path(args.out)
    stale = []
    for name, value in replies().items():
        path = out / name
        text = render(value)
        if args.check:
            if not path.exists() or path.read_text() != text:
                stale.append(str(path))
            continue
        out.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    if stale:
        print(
            "stale fixtures (make kohler-fixtures):",
            *stale,
            sep="\n  ",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
