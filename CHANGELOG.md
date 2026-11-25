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

<!-- #ifdef DRIVERCENTRAL -->

## Unreleased

### Added

- Added the Kohler Generators and Kohler Generator drivers to DriverCentral

<!-- #endif -->

<!-- #ifndef DRIVERCENTRAL -->

## Unreleased

### Added

- Added the Kohler Generators and Kohler Generator drivers, which sign in to a
  KOHLER account and add a driver for each generator on it
- Added each generator's status, power source and readings as variables, with
  temperatures in the project's scale
- Added events for a utility outage and its end, the engine starting and
  stopping, an exercise, a fault or warning, the switch leaving Auto,
  maintenance falling due and a low battery
- Added conditionals and contact outputs for generator power, running, fault and
  the switch, so outage programming works with any contact input
- Added commands to start and stop an exercise, change the exercise schedule and
  switch load-shed loads
- Added a generator page in the Control4 app with the generator's power,
  readings, exercise schedule, loads, alerts and service details
- Added automatic driver updates

<!-- #endif -->
