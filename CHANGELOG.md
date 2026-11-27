# <span style="color:#336EE5">Changelog</span>

<!--
Template for a new release entry (copy below the heading, fill in, uncomment):

## v[Version] - YYYY-MM-DD

### Added
- Added

### Fixed
- Fixed

### Changed
- Changed

### Removed
- Removed
-->

## Unreleased

<!-- #ifndef DRIVERCENTRAL -->

### Fixed

- Fixed Update Drivers and Automatic Updates failing to install a release whose
  driver files were too large to download.

<!-- #endif -->

## v20261127 - 2026-11-27

### Added

- Added a Utility power conditional for programming.

### Fixed

- Fixed a generator showing Online with old readings while KOHLER doesn't answer
  the driver's reads. It now shows KOHLER not answering after two Poll
  Intervals.
- Fixed Account Disconnected not firing when KOHLER refuses the driver's reads.
- Fixed a generator's icon in the Control4 app showing Standby after a
  controller restart, until its first reading.
- Fixed a load-shed load named Watts or Percent taking over the Load Watts or
  Load Percent variable, and Load Control off deleting it.
- Fixed a controller restart firing Generator Offline and Generator Online for a
  generator that didn't change.
- Fixed a controller restart firing the Fault contact and Fault variable twice
  for a fault that didn't change.
- Fixed a generator staying online when its Kohler Generators driver is deleted
  or its connection removed.
- Fixed a Poll Interval change while the Kohler Generators driver waits to retry
  KOHLER sending reads before the wait ends.
- Fixed a load-shed load named Control changing the Load Control property.
- Fixed Load Control Off leaving load variables from before a controller
  restart.
- Fixed a generator's Driver Status and its page in the Control4 app naming the
  same state differently.

### Changed

- Changed Account Connected to fire after each driver or controller start too.
- Changed Reset Driver on the Kohler Generators driver to reset its Account
  Connected variable too.
- Changed a load that leaves the generator to log that its variable is kept for
  programming.

<!-- #ifndef DRIVERCENTRAL -->

### Removed

- Removed Automatic Updates from the Kohler Generator driver. The Kohler
  Generators driver's setting updates both drivers.

<!-- #endif -->

## v20261125 - 2026-11-25

### Added

- Added the Kohler Generators and Kohler Generator drivers for KOHLER home
  standby generators
- Added each generator's status, power source and readings in Control4, and its
  state on its icon in the Control4 app
- Added programming for utility outages, the engine running, exercises, faults
  and maintenance
- Added contact outputs, so any driver with a contact input can follow the
  generator
- Added starting an exercise, changing the exercise schedule and switching
  load-shed loads from Control4
- Added a generator page in the Control4 app
  <!-- #ifdef DRIVERCENTRAL -->
- Added a Support Code property, Cloud Monitoring and a Diagnostics Snapshot
  action
  <!-- #endif -->
