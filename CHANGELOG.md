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

### Added

- Added a Utility power conditional for programming.

### Fixed

- Fixed Account Disconnected not firing when KOHLER refuses the driver's reads.
- Fixed a generator's icon in the Control4 app showing Standby after a
  controller restart, until its first reading.
- Fixed a load-shed load named Watts or Percent taking over the Load Watts or
  Load Percent variable, and Load Control off deleting it.

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
