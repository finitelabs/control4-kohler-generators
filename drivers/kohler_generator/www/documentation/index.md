<!-- Copyright 2026 Finite Labs, LLC. All rights reserved. -->

<style>
@media print {
   .noprint {
      visibility: hidden;
      display: none;
   }
   * {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }
}
</style>

<img alt="Kohler Generator" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#336EE5">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or KOHLER.

This driver represents a single KOHLER home standby generator in Control4. It
does not reach the cloud itself. It binds to the **Kohler Generators** account
driver, which hands it the generator's details on every read. It shows the
generator in its room in the Control4 app; selecting it there does not run the
generator.

# <span style="color:#336EE5">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Installer Setup](#installer-setup)
  - [Adding the Driver](#adding-the-driver)
  - [Driver Properties](#driver-properties)
    - [Cloud Settings](#cloud-settings)
    - [Generator](#generator)
    - [Driver Settings](#driver-settings)
  - [Connections](#connections)
- [Programming Reference](#programming-reference)
- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#336EE5">System Requirements</span>

- Control4 OS 3.3.0 or later
- The **Kohler Generators** account driver, signed in to the KOHLER account the
  generator is on

# <span style="color:#336EE5">Installer Setup</span>

## Adding the Driver

Run **Add Generators** on the **Kohler Generators** driver: it adds and binds
one of these drivers per generator. To add one yourself, add the "Kohler
Generator" driver and bind its `Kohler Generator` connection to a generator
connection on the account driver in the "Connections" tab.

## Driver Properties

### Cloud Settings

<!-- #ifdef DRIVERCENTRAL -->

#### Cloud Status (read-only)

Displays the DriverCentral cloud license status.

<!-- #endif -->

#### Automatic Updates \[ Off | **_On_** \]

Enables or disables automatic driver updates. Changing it here changes it on the
Kohler Generators driver and every Kohler Generator driver.

### Generator

The details below come from the KOHLER account and fill in once the account
driver has read the generator.

#### Generator Name (read-only)

The generator's name in the KOHLER app.

#### Auto Rename Driver \[ Off | **_On_** \]

When On, this driver is named after the generator, and renamed when the
generator is renamed in the KOHLER app.

#### Model (read-only)

The generator's model.

#### Serial Number (read-only)

The generator's serial number.

#### Controller (read-only)

The generator's controller.

#### Firmware Version (read-only)

The controller's firmware version.

#### Fuel Type (read-only)

The fuel the generator runs on.

#### Connection Type (read-only)

How the generator reaches the KOHLER cloud.

#### Dealer (read-only)

The dealer on the account for this generator, with their phone number.

### Driver Settings

#### Driver Status (read-only)

Displays `Online` while the generator is reaching the KOHLER cloud,
`Generator offline` while it is not, and `Offline` while the account driver is
signed out or the generator is no longer on the account.

#### Driver Version (read-only)

Displays the current version of the driver.

<!-- #ifdef DRIVERCENTRAL -->

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug \]

Sets the logging level. Default is `3 - Info`. While a Support Code has
Composer's Lua tab open, it also offers `5 - Trace` and `6 - Ultra`.

<!-- #else -->

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

<!-- #endif -->

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`.

<!-- #ifdef DRIVERCENTRAL -->

#### Support Code

Leave it blank unless Finite Labs support gives you a code: for an hour, it
opens Composer's Lua tab to this driver and adds `5 - Trace` and `6 - Ultra` to
Log Level.

#### Cloud Monitoring \[ Disabled | **_Enabled_** \]

When Enabled, the driver sends Finite Labs a short report once an hour, and a
report of each error it hits, at most 10 a minute. Set it to Disabled to send
nothing. The Kohler Generators driver's documentation lists what a report holds.

<!-- #endif -->

## Connections

### Kohler Generator (consumer)

Binds to one generator connection on the **Kohler Generators** driver, with
binding class `KOHLER_GENERATOR`.

# <span style="color:#336EE5">Programming Reference</span>

### Variables

| Variable | Type    | Description                                         |
| -------- | ------- | --------------------------------------------------- |
| ONLINE   | Boolean | Whether the generator is reaching the KOHLER cloud. |

### Events

| Event             | Description                                                                                                        |
| ----------------- | ------------------------------------------------------------------------------------------------------------------ |
| Generator Online  | Fires when the generator reaches the KOHLER cloud again.                                                           |
| Generator Offline | Fires when the generator stops reaching the KOHLER cloud, leaves the account, or the account driver is signed out. |

### Conditionals

| Conditional          | Description                                           |
| -------------------- | ----------------------------------------------------- |
| Generator connection | Tests whether the generator is `Online` or `Offline`. |

# <span style="color:#336EE5">Support</span>

<!-- #ifdef DRIVERCENTRAL -->

If you have any questions or issues integrating this driver with Control4, you
can contact us at [%%SUPPORT_EMAIL%%](mailto:__SUPPORT_EMAIL__) or call/text us
at [%%SUPPORT_PHONE%%](tel:__SUPPORT_PHONE__).

<!-- #else -->

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-kohler-generators/issues/new

<!-- #endif -->

<!-- #embed-changelog -->
