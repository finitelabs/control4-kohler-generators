# Mock KOHLER generator cloud

A stand-in for the KOHLER home-generator service, for testing the driver without
a generator. One process serves the token endpoint, the homeowner API and a
control API on one port. Every value in it is made up.

## Running it

```bash
make mock-kohler                                   # instances/demo.json on port 18400
make mock-kohler MOCK_ARGS="--tls --speed 60"      # HTTPS, generators' clock 60 times faster
make mock-kohler MOCK_CONFIG=instances/single.json # one generator
make test-mock-kohler                              # the mock's own tests
```

`--tls` serves HTTPS with a self-signed certificate (or `--cert` and `--key`).
The mock listens on every address, so a controller on the same network can reach
it. `python -m mock_kohler --list` lists the profiles.

## Instances

| File           | Account                                      | Generators                                        |
| -------------- | -------------------------------------------- | ------------------------------------------------- |
| `demo.json`    | demo@example.com, password `demo-password-1` | 58001 and 58002 at Demo Home, 58003 at Demo Cabin |
| `single.json`  | the same account                             | 58001                                             |
| `offline.json` | the same account                             | 58004, offline                                    |

Each instance also sets the client the token endpoint accepts (`mock-client`,
secret `mock-client-secret`, sent with HTTP Basic) and the API key every API
call needs (`mock-api-key`, in an `ApiKey` header).

## Profiles

| Profile                | Generator                                                                                                                        |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `air-20kw-blue-ng`     | 20 kW air-cooled, RDC2 Blue Board, natural gas, load-shed module and PIM, negative load readings, seven-digit fractional seconds |
| `air-14kw-redgreen-lp` | 14 kW air-cooled, RDC2 Red or Green Board, propane, no load module, exercise and maintenance times in local time with no offset  |
| `liquid-48kw-blue-ng`  | 48 kW liquid-cooled, coolant temperature and oil pressure, monthly loaded exercise                                               |
| `air-26kw-offline`     | 26 kW air-cooled, offline since three days before start                                                                          |

## What it does

- Sign-in with the password grant and the refresh grant. Refresh tokens rotate:
  each refresh returns a new one and the old one stops working. Access tokens
  last `access_ttl_s` (3600).
- `GET /kem/api/v3/homeowner/me`, `homeowner/homes`, `notifications`, and per
  generator `devices/{id}`, `alerts`, `events` and `maintenance_notes`.
- Exercise start and stop, the exercise schedule (`PUT` and
  `DELETE devices/{id}/exercise`), load-shed relays
  (`peripherals/{definitionId}/set_value`) and renaming a relay or output.
  Starting an exercise is refused when the generator is offline, not ready to
  run, not in Auto or already running. PIM outputs are read only.
- Each generator runs: an exercise cranks, runs for its duration, cools down and
  stops; a loaded exercise moves the house to generator power. A utility outage
  starts the engine after a short delay and moves the house to generator power;
  when the utility returns the house moves back, then the engine cools down and
  stops. Scheduled exercises run at their time. Each change adds events and
  notifications and moves `statusUpdateTimestamp`; runtime hours accrue while
  the engine runs.
- While a generator is offline its record stays as it was, with an extra "Not
  Connected" alert; events from that time arrive when it comes back.
- MAC addresses come byte-reversed, as the service sends them.

## Control API

`GET /_mock` lists the actions and `GET /_mock/state` shows each generator's
state and the last 200 calls. Actions are `POST /_mock/<action>` with a JSON
body:

| Action         | Body                                     | Effect                                                               |
| -------------- | ---------------------------------------- | -------------------------------------------------------------------- |
| `outage`       | `{device}`                               | Utility power fails                                                  |
| `restore`      | `{device}`                               | Utility power returns                                                |
| `exercise_now` | `{device}`                               | The scheduled exercise starts now                                    |
| `fault`        | `{device, event?}`                       | A shutdown fault: engine stops, status Shutdown                      |
| `warning`      | `{device, event?}`                       | A warning alert                                                      |
| `clear`        | `{device}`                               | Clears alerts and any fault                                          |
| `battery`      | `{device, low}`                          | Starting battery low, or back to normal                              |
| `switch`       | `{device, position}`                     | Switch to `Off`, `Auto` or `Manual`                                  |
| `online`       | `{device, online}`                       | The generator's link to the service up or down                       |
| `account`      | `{email, op, device, profile?, home?}`   | Add or remove a generator on an account                              |
| `slow`         | `{seconds, target?}`                     | Delay every answer (`api`, `token` or `all`); 0 turns it off         |
| `fail`         | `{status, count, target?, retry_after?}` | Answer the next calls with 429 or a 5xx                              |
| `revoke`       | `{email?}`                               | Revoke refresh tokens                                                |
| `expire`       | `{email?}`                               | Expire access tokens now                                             |
| `password`     | `{email, password}`                      | Change the password; refresh tokens are revoked                      |
| `refuse`       | `{email, error}`                         | Refuse sign-ins with `mfa_required` or `access_denied`; `null` stops |
| `advance`      | `{seconds}`                              | Jump the generators' clock                                           |
| `reset`        | `{}`                                     | Generators and accounts back to the config; tokens stay valid        |

`device` is the generator id (58001 to 58004 in the bundled instances).

```bash
curl -X POST localhost:18400/_mock/outage -d '{"device": 58001}'
```
