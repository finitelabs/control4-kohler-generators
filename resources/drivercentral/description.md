<p><img src="FACTS-STRIP-URL" alt="" width="1200" height="68" /></p>

## Overview

*This software is neither affiliated with nor endorsed by either Control4 or
KOHLER.*

Bring KOHLER home standby generators into Control4. Sign in once with the
homeowner's KOHLER account, and every generator on it appears in its room in the
Control4 app, with its power source, status and readings, and an icon that shows
its state at a glance. Programming can react when the utility goes out or the
generator starts, and can start an exercise or switch load-shed loads without
opening the KOHLER app.

## Features

- Each generator's status, power source and readings in Control4, with its state
  on its icon in the Control4 app
- A generator page in the Control4 app, with the exercise schedule, loads,
  alerts and service details
- Programming for utility outages, the engine running, exercises, faults and
  maintenance
- Contact outputs, so any driver with a contact input can follow the generator
- Starting and stopping an exercise, changing the exercise schedule and
  switching load-shed loads from Control4
- One sign-in for the whole account, with a driver added, bound and named for
  each generator on its own

## Included drivers

### Kohler Generators

The account driver, and the one to add first. It signs in to the KOHLER account,
finds every generator on it, and adds a Kohler Generator driver for each one.

### Kohler Generator

One for each generator, added by the account driver. It shows the generator in
its room in the Control4 app, opens its generator page, and carries its events,
conditionals, contact outputs and commands.

## System requirements

- Control4 OS 3.3+
- A KOHLER account with at least one generator set up in the KOHLER Energy
  Management app
- Internet access from the Control4 controller

## Compatibility

Any KOHLER home standby generator set up in the KOHLER Energy Management app
works. The driver reads the generator through KOHLER's cloud, so a reading can
be a few minutes old, and a reading the generator's controller does not report
has no value.
