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
driver, which hands it the generator's details, status and alerts on every read.
It shows the generator in its room in the Control4 app, where selecting it opens
the generator page. Opening the page does not run the generator. The generator's
icon in the Control4 app shows its state.

Programming can react to a utility outage, the engine starting and stopping, an
exercise, a fault or warning, the switch leaving Auto and maintenance falling
due, and four contact outputs follow the generator's power, running, fault and
switch state. Programming can also start and stop an exercise, change the
exercise schedule and switch the generator's load-shed loads.

# <span style="color:#336EE5">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Installer Setup](#installer-setup)
  - [Adding the Driver](#adding-the-driver)
  - [Driver Properties](#driver-properties)
    - [Cloud Settings](#cloud-settings)
    - [Driver Settings](#driver-settings)
    - [Generator](#generator)
  - [Connections](#connections)
- [Status and Readings](#status-and-readings)
- [The Generator Page](#the-generator-page)
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

The **Kohler Generators** driver adds and binds one of these drivers per
generator after it signs in. To add one yourself, add the "Kohler Generator"
driver and bind its `Kohler Generator` connection to a generator connection on
the account driver in the "Connections" tab.

## Driver Properties

### Cloud Settings

<!-- #ifdef DRIVERCENTRAL -->

#### Cloud Status (read-only)

Displays the DriverCentral cloud license status.

<!-- #endif -->

#### Automatic Updates \[ Off | **_On_** \]

Enables or disables automatic driver updates. Changing it here changes it on the
Kohler Generators driver and every Kohler Generator driver.

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

### Generator

The details below come from the KOHLER account and fill in once the account
driver has read the generator.

#### Generator Name (read-only)

The generator's name in the KOHLER app.

#### Auto Rename Driver \[ Off | **_On_** \]

When On, this driver is named after the generator, and renamed when the
generator is renamed in the KOHLER app. A generator with no name in the KOHLER
app, or named only by its serial number, is named KOHLER and its model instead.

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

#### Load Control \[ Off | **_On_** \]

Shows the generator's load-shed loads as variables and lets programming switch
them. The driver sets it from the generator's first reading: `On` when the
generator has a load control module, `Off` when it has none. Your choice holds
after that. While it is `Off`, the load variables are removed and **Set Load**
does nothing.

#### Exercise Schedule (read-only)

How often the generator exercises, on what day and time, in which mode and for
how long, or `None`.

#### Last Maintenance (read-only)

When the generator was last serviced.

#### Next Maintenance (read-only)

When the generator is next due for service.

## Connections

### Kohler Generator (consumer)

Binds to one generator connection on the **Kohler Generators** driver, with
binding class `KOHLER_GENERATOR`.

### Contact Outputs

Four `CONTACT_SENSOR` outputs, each closed while its condition holds. Bind them
to contact sensor drivers or other devices that take a contact.

| Output             | Closed while                          |
| ------------------ | ------------------------------------- |
| On Generator Power | The house is on generator power       |
| Running            | The engine runs                       |
| Fault              | The generator has a fault             |
| Not In Auto        | The generator's switch is not in Auto |

# <span style="color:#336EE5">Status and Readings</span>

The account driver reads the generator every Poll Interval, and every 15 seconds
while the engine runs or the utility is out, and its alerts and event log every
2 minutes. The KOHLER cloud updates each generator's readings on its own
schedule, so a reading can be a few minutes old.

A reading the generator's controller does not report has no value. Temperatures
show in the project's temperature scale.

After the driver or the controller restarts, the first read compares the
generator with how it was before the restart: a restart during an outage is not
mistaken for a new one, and an outage that started while the controller was off
fires its events and contact programming once. An event the generator logged in
the last 5 minutes still fires.

# <span style="color:#336EE5">The Generator Page</span>

Selecting the generator in the Control4 app, on a touchscreen or a phone, opens
its page. The page shows:

- **Top**: whether the house is on utility or generator power, the engine's
  state, the switch position and when the generator last reported.
- **Exercise**: the schedule, the next and last exercise, and buttons to start
  or stop an exercise and change the schedule.
- **Now**: the readings this generator's controller reports.
- **Loads**: a switch for each load-shed load, shown only when Load Control is
  On and the generator has a load control module.
- **Alerts**: active alerts, with the event log under History.
- **Service**: maintenance dates, the dealer and the generator's details.

Opening or refreshing the page never runs the generator. Start asks first, and
says what happens: the engine starts and, for a Loaded Full Speed exercise, the
house moves to generator power until the exercise ends. The page's commands are
the driver's own Start Exercise, Stop Exercise, Set Exercise Schedule and Set
Load commands, so they are refused for the same reasons. A button that would be
refused is greyed out with the reason under it.

When the account driver is not signed in, or the generator is offline, the page
says so and offers Try again where a new read can help.

# <span style="color:#336EE5">Programming Reference</span>

### Variables

| Variable                | Type    | Description                                                        |
| ----------------------- | ------- | ------------------------------------------------------------------ |
| Online                  | Boolean | Whether the generator is reaching the KOHLER cloud.                |
| Status                  | String  | The generator's status as the KOHLER app shows it.                 |
| Engine State            | String  | The engine's state as the KOHLER app shows it.                     |
| Power Source            | String  | `Utility` or `Generator`.                                          |
| On Generator Power      | Boolean | Whether the house is on generator power.                           |
| Running                 | Boolean | Whether the engine runs.                                           |
| Switch Position         | String  | `Auto`, `Off` or `Manual`.                                         |
| In Auto                 | Boolean | Whether the switch is in Auto.                                     |
| Fault                   | Boolean | Whether the generator has a fault.                                 |
| Active Alerts           | Number  | How many alerts are active.                                        |
| Last Alert              | String  | The newest active alert.                                           |
| Utility Voltage         | Number  | Volts.                                                             |
| Generator Voltage       | Number  | Volts.                                                             |
| Load Watts              | Number  | The load on the generator, in watts.                               |
| Load Percent            | Number  | The load as a percentage of the generator's rating.                |
| Frequency               | Number  | Hertz.                                                             |
| Engine RPM              | Number  | Engine speed.                                                      |
| Battery Voltage         | Number  | Volts.                                                             |
| Oil Pressure OK         | Boolean | Whether the oil pressure is OK.                                    |
| Controller Temperature  | Number  | In the project's scale.                                            |
| Lube Oil Temperature    | Number  | In the project's scale.                                            |
| Coolant Temperature     | Number  | In the project's scale.                                            |
| Runtime Hours           | Number  | Hours the engine has run.                                          |
| Operation Hours         | Number  | Hours the controller has been on.                                  |
| Hours Since Maintenance | Number  | Engine hours since the last service.                               |
| Last Ran                | String  | When the engine last ran.                                          |
| Next Exercise           | String  | When the next exercise starts.                                     |
| Next Maintenance        | String  | When the next service is due.                                      |
| Maintenance Due         | Boolean | Whether the service is due.                                        |
| Load _name_             | Boolean | One per load-shed load while Load Control is on, whether it is on. |

### Events

| Event                  | Description                                                                                                        |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Generator Online       | Fires when the generator reaches the KOHLER cloud again.                                                           |
| Generator Offline      | Fires when the generator stops reaching the KOHLER cloud, leaves the account, or the account driver is signed out. |
| Utility Power Lost     | Fires when the utility power goes out.                                                                             |
| Utility Power Restored | Fires when the utility power comes back.                                                                           |
| Engine Started         | Fires when the engine starts.                                                                                      |
| Engine Stopped         | Fires when the engine stops.                                                                                       |
| Exercise Started       | Fires when an exercise starts.                                                                                     |
| Exercise Ended         | Fires when an exercise ends.                                                                                       |
| Fault                  | Fires when the generator logs a fault.                                                                             |
| Warning                | Fires when the generator logs a warning.                                                                           |
| Alerts Cleared         | Fires when the last active alert clears.                                                                           |
| Switch Not In Auto     | Fires when the switch moves out of Auto.                                                                           |
| Switch Back In Auto    | Fires when the switch moves back to Auto.                                                                          |
| Maintenance Due        | Fires when the service falls due.                                                                                  |
| Low Battery            | Fires when the generator logs a low battery.                                                                       |

### Conditionals

| Conditional           | Description                                                         |
| --------------------- | ------------------------------------------------------------------- |
| Generator connection  | Tests whether the generator is `Online` or `Offline`.               |
| Power source          | Tests whether the house is on `Generator Power` or `Utility Power`. |
| Engine running status | Tests whether the engine is `Running` or `Not Running`.             |
| Exercise status       | Tests whether the generator is `Exercising` or `Not Exercising`.    |
| Switch position       | Tests whether the switch is `In Auto` or `Not In Auto`.             |
| Fault status          | Tests whether the generator is `Faulted` or `Not Faulted`.          |
| Maintenance status    | Tests whether the service is `Due` or `Not Due`.                    |

The number variables can be compared in programming too.

### Commands

Each command goes to KOHLER through the account driver, and the generator is
read again right after. For 30 seconds, **Driver Status** shows whether KOHLER
took the command, or why it was not sent. A command is sent once: if KOHLER does
not answer, check the generator before sending it again.

| Command               | What it does                                                                                                                                                                                                                             |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Start Exercise        | Starts the engine now for an exercise of the scheduled length. `Unloaded` and `Unloaded Full Speed` run the engine with the house left on utility power. `Loaded Full Speed` also moves the house onto generator power for the exercise. |
| Stop Exercise         | Ends the exercise that is running and stops the engine.                                                                                                                                                                                  |
| Set Exercise Schedule | Sets how often the generator exercises (`Weekly`, `Every Other Week` or `Monthly`), the day and time of the next one, the mode, and how long it runs, from 5 to 60 minutes. Enter the time as `14:30` or `2:30 PM`.                      |
| Set Load              | Turns a load-shed load on or off, as the switch for it in the KOHLER app does. Needs Load Control on.                                                                                                                                    |
| Refresh               | Reads the generator from KOHLER now.                                                                                                                                                                                                     |

The driver refuses a command the KOHLER app would refuse, and sends nothing:

- Any command while the generator is offline, while the account driver is
  reconnecting or its reads are paused, or when the generator's last reading is
  older than two of the account driver's Poll Intervals.
- **Start Exercise** while utility power is out, the engine already runs, the
  switch is not in Auto, or the generator is not ready to run.
- **Stop Exercise** when no exercise is running.

Selecting the generator in the Control4 app never starts the engine.

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
