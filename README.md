<!-- Copyright 2026 Finite Labs, LLC. All rights reserved. -->

<img alt="Kohler Generators" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#336EE5">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or KOHLER.

Bring KOHLER home standby generators into Control4. This account driver signs in
to the homeowner's KOHLER account, finds every generator on it, and adds a
companion **Kohler Generator** driver for each one, so each generator appears in
its room in the Control4 app.

# <span style="color:#336EE5">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Included Drivers](#included-drivers)
  - [Kohler Generators](#kohler-generators)
  - [Kohler Generator](#kohler-generator)
- [Installer Setup](#installer-setup)
  - [Driver Installation](#driver-installation)
  - [Driver Setup](#driver-setup)
    - [Driver Properties](#driver-properties)
      - [Cloud Settings](#cloud-settings)
      - [Account Settings](#account-settings)
      - [Driver Settings](#driver-settings)
      - [Generator Settings](#generator-settings)
    - [Driver Actions](#driver-actions)
  - [Connections](#connections)
  - [Programming Reference](#programming-reference)
- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#336EE5">System Requirements</span>

- Control4 OS 3.3.0 or later
- A KOHLER account with at least one generator set up in the KOHLER Energy
  Management app
- Internet access from the Control4 controller

# <span style="color:#336EE5">Included Drivers</span>

## Kohler Generators

The account driver, and the driver to add first. Enter the KOHLER account's
email and password; it signs in, finds every generator on the account, and
creates a connection for each one. The **Kohler Generator** drivers bind to
those connections, so the account driver is the only place the account is signed
in and the only driver that reaches the KOHLER cloud.

**Key features:**

- Sign-in with the KOHLER account's email and password
- Automatic discovery of every generator on the account
- One companion generator driver per generator, added, bound, and named by the
  Add Generators action
- Account Connected and Account Disconnected events for programming
- Generators read on a configurable poll interval

## Kohler Generator

The companion driver. One is added per generator, bound to its connection on the
account driver. It shows the generator in its room and reports whether the
generator is reaching the KOHLER cloud.

**Key features:**

- The generator's name, model, serial number, controller, firmware, fuel,
  connection and dealer
- Generator Online and Generator Offline events for programming

# <span style="color:#336EE5">Installer Setup</span>

> ⚠️ Only a **_single_** Kohler Generators driver is required per KOHLER
> account. Add Generators adds one **Kohler Generator** driver per generator.

## Driver Installation

1. Download the latest `control4-kohler-generators.zip` from
   [Github](https://github.com/finitelabs/control4-kohler-generators/releases/latest).

1. Extract and
   [install](https://www.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/adding_drivers_manually.htm)
   all `.c4z` files.

1. Use the "Search" tab to find the "Kohler Generators" driver and add it to
   your project.

1. Enter the KOHLER account's [`Email`](#email) and [`Password`](#password).

1. After a few moments the [`Login Status`](#login-status-read-only) shows
   `Logged In` and the [`Driver Status`](#driver-status-read-only) shows
   `Connected` with the number of generators found. If it does not, set the
   [`Log Mode`](#log-mode--off--print--log--print-and-log-) property to `Print`,
   run [Reconnect](#reconnect), and check the Lua output window for details.

1. Run the [Add Generators](#add-generators) action. It adds a "Kohler
   Generator" driver for each generator on the account, binds it, and names it
   after the generator.

You can also add the "Kohler Generator" drivers yourself and bind each one to a
generator connection on the "Kohler Generators" driver in the "Connections" tab;
Add Generators then uses any unbound ones in this driver's room before adding
new drivers.

Each companion driver includes its own documentation accessible from within
Composer Pro. Refer to the **Kohler Generator** driver documentation for its
property and programming reference.

## Driver Setup

### Driver Properties

#### Cloud Settings

##### Automatic Updates \[ Off | **_On_** \]

Enables or disables automatic driver updates from GitHub releases.

##### Update Channel \[ **_Production_** | Prerelease \]

Sets the update channel considered during automatic updates from GitHub
releases.

#### Account Settings

##### Email

The email address the homeowner signs in to the KOHLER Energy Management app
with.

##### Password

The KOHLER account's password. It is hidden in Composer and never written to the
logs.

##### Login Status (read-only)

Displays the sign-in state: `Logged In`, `Logging in...`,
`Enter email and password`, `Invalid email or password`, `Sign-in refused` or
`Login failed`. `Sign-in refused` means KOHLER would not let the account sign in
here, most often because the account asks for a second sign-in step; the driver
does not try again until the email or password changes or you run Reconnect.
After `Login failed` the driver tries again on its own.

#### Driver Settings

##### Driver Status (read-only)

Displays the current status of the driver (`Connected (2 generators)` once
signed in).

##### Driver Version (read-only)

Displays the current version of the driver.

##### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

##### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`.

#### Generator Settings

##### Poll Interval \[ 30 seconds | **_60 seconds_** | 120 seconds | 300 seconds | 900 seconds \]

Sets how often the driver reads the account's generators. Default is
`60 seconds`.

### Driver Actions

#### Update Drivers

Trigger the driver to update from the latest release on GitHub, regardless of
the current version.

#### Add Generators

Adds a **Kohler Generator** driver for every generator on the account that
doesn't have one, and binds it. Any Kohler Generator drivers in this driver's
room that aren't bound are used first. Each driver is named after its generator,
and follows it when it is renamed in the KOHLER app unless that driver's **Auto
Rename Driver** property is Off.

Run it again after adding a generator to the account. A driver whose generator
is no longer on the account is renamed with ` - REMOVED FROM KOHLER`; copy any
programming from it and delete it. If the generator comes back to the account,
the next Add Generators restores the name.

#### Refresh Generators

Re-reads the account right away, picking up new generators, new names and
changed details.

#### Reconnect

Signs in to KOHLER again with the email and password entered.

#### Reset Driver

> ⚠️ This will reset all connection bindings and delete any programming
> associated with them.

Signs out and removes all generator connections, then signs in again and
rediscovers the account from scratch.

**Parameters:**

- **Are You Sure?** \[ **_No_** | Yes \] - Confirmation to reset the driver.

## Connections

### `{Generator Name}` (provider, dynamic)

One per generator on the account, created once signed in, with binding class
`KOHLER_GENERATOR`. Bind each to a **Kohler Generator** driver; **Add
Generators** does this for you.

> **Note:** `{Generator Name}` is the generator's name in the KOHLER app.

## Programming Reference

### Variables

| Variable          | Type    | Description                                     |
| ----------------- | ------- | ----------------------------------------------- |
| Account Connected | Boolean | Whether the driver is signed in to the account. |

### Events

| Event                | Description                                                                                                                          |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Account Connected    | Fires when the driver signs in to the KOHLER account, or signs in again after losing it. Not fired when a reboot finds it as it was. |
| Account Disconnected | Fires when the driver loses its KOHLER sign-in. Use it to send the integrator a notification.                                        |

### Conditionals

| Conditional               | Description                                                  |
| ------------------------- | ------------------------------------------------------------ |
| KOHLER account connection | Tests whether the account is `Connected` or `Not Connected`. |

### Commands

| Command            | Parameters | Description                                         |
| ------------------ | ---------- | --------------------------------------------------- |
| Refresh Generators | None       | Re-reads every generator on the account right away. |

# <span style="color:#336EE5">Support</span>

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-kohler-generators/issues/new

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
