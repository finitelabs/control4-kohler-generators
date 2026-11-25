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

- **Kohler Generators** account driver, which signs in to a KOHLER account with
  its email and password, finds the generators on it and reads them on a poll
  interval you choose, signing in again on its own when the sign-in lapses.
- **Kohler Generator** companion, one per generator, added, bound and named by
  the Add Generators action, which shows the generator in its room with its
  model, serial number, controller, firmware, fuel, connection and dealer.
- Generator status, power source and readings as variables: utility and
  generator voltage, load, frequency, engine speed, battery, temperatures in the
  project's scale, run hours, the exercise schedule and maintenance dates.
- Events for a utility outage and its end, the engine starting and stopping, an
  exercise, a fault or warning, alerts clearing, the switch leaving and
  returning to Auto, maintenance falling due and a low battery.
- Conditionals and contact outputs for generator power, running, fault and the
  switch, so outage programming works with any contact input.
- Account Connected and Account Disconnected events, and Generator Online and
  Generator Offline events, for programming.
