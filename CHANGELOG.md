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
- Account Connected and Account Disconnected events, and Generator Online and
  Generator Offline events, for programming.
