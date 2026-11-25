"""The mock cloud: one aiohttp app serving the token endpoint, the homeowner API and /_mock/."""

import asyncio
import base64
import copy
import hashlib
import hmac
import html
import json
import logging
import secrets
from pathlib import Path

from aiohttp import web

from . import ROOT
from .clock import Clock, SimClock
from .generator import Generator, Ids, Refused

log = logging.getLogger(__name__)

PROFILES = ROOT / "profiles"
TOKEN_PATH = "/oauth2/default/v1/token"
API = "/kem/api/v3"
SCOPES = {"openid", "profile", "offline_access", "email"}
CALL_LOG = 200

DEFAULT_SETTINGS = {
    "access_ttl_s": 3600,
    "revoke_on_password_change": True,
    "public_url": None,
}
DEFAULT_CLIENT = {"id": "mock-client", "secret": "mock-client-secret"}
DEFAULT_API_KEY = "mock-api-key"
REFUSALS = {"mfa_required": 400, "access_denied": 401}


def load_profile(ref):
    path = Path(ref)
    if not path.suffix:
        path = PROFILES / f"{ref}.json"
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def json_response(body, status=200, headers=None):
    return web.json_response(body, status=status, headers=headers)


def oauth_error(status, error, description):
    return json_response({"error": error, "error_description": description}, status)


def api_error(status, message, headers=None):
    return json_response({"message": message}, status, headers)


class Account:
    def __init__(self, spec):
        self.email = spec["email"]
        self.password = spec["password"]
        self.id = int(spec["id"])
        self.sub = spec["sub"]
        self.first = spec.get("firstName", "Demo")
        self.last = spec.get("lastName", "Homeowner")
        self.refuse = spec.get("refuse")
        self.homes = []
        self.generators = []

    def me(self):
        return {
            "id": self.id,
            "email": self.email,
            "firstName": self.first,
            "lastName": self.last,
            "hasAcceptedTC": True,
            "deviceSerialNumbers": [g.serial for g in self.generators],
            "hasApprovedDevices": bool(self.generators),
            "hasAppAccount": True,
            "hasAcceptedMarketingOutreach": False,
        }


class Cloud:
    def __init__(self, config, clock=None, speed=None):
        self.config = copy.deepcopy(config)
        self.base = clock or Clock()
        speed = speed if speed is not None else self.config.get("speed", 1.0)
        self.sim = SimClock(self.base, speed)
        client = {**DEFAULT_CLIENT, **self.config.get("client", {})}
        self.client_id, self.client_secret = client["id"], client["secret"]
        self.api_key = self.config.get("apiKey", DEFAULT_API_KEY)
        self.secret = secrets.token_bytes(32)
        self.access = {}
        self.refresh = {}
        self.fail = None
        self.slow = None
        self.calls = []
        self.ids = Ids()
        self._load()
        self.app = self._build_app()
        self.runner = None

    def _load(self):
        self.settings = {**DEFAULT_SETTINGS, **self.config.get("settings", {})}
        self.accounts = []
        self.generators = {}
        self.detached = {}
        for spec in self.config.get("accounts", []):
            acct = Account(spec)
            for h in spec.get("homes", []):
                home = {k: v for k, v in h.items() if k != "generators"}
                acct.homes.append(home)
                for g in h.get("generators", []):
                    self._make_generator(g, home, acct)
            self.accounts.append(acct)

    def _make_generator(self, spec, home, acct):
        profile = (
            load_profile(spec["profile"]) if isinstance(spec["profile"], str) else spec["profile"]
        )
        profile = {**profile, **spec.get("overrides", {})}
        gen = Generator(spec, profile, home, acct, self.sim, self.ids)
        if gen.id in self.generators:
            raise ValueError(f"generator id {gen.id} is used twice")
        self.generators[gen.id] = gen
        acct.generators.append(gen)
        return gen

    # ─── Lifecycle ────────────────────────────────────────────────────────

    def _build_app(self):
        app = web.Application(middlewares=[self.middleware])
        r = app.router
        r.add_get("/", self.index)
        r.add_post(TOKEN_PATH, self.token)
        r.add_get(f"{API}/homeowner/me", self.me)
        r.add_get(f"{API}/homeowner/homes", self.homes)
        r.add_get(f"{API}/notifications", self.notifications)
        r.add_get(API + "/devices/{id}", self.device)
        r.add_get(API + "/devices/{id}/alerts", self.alerts)
        r.add_get(API + "/devices/{id}/events", self.events)
        r.add_get(API + "/devices/{id}/maintenance_notes", self.maintenance_notes)
        r.add_post(API + "/devices/{id}/exercise/start", self.exercise_start)
        r.add_post(API + "/devices/{id}/exercise/stop", self.exercise_stop)
        r.add_put(API + "/devices/{id}/exercise", self.exercise_put)
        r.add_delete(API + "/devices/{id}/exercise", self.exercise_delete)
        r.add_post(API + "/devices/{id}/peripherals/{param}/set_value", self.set_value)
        r.add_put(API + "/devices/{id}/peripherals/{param}", self.rename)
        r.add_get("/_mock", self.mock_index)
        r.add_get("/_mock/state", self.mock_state)
        r.add_post("/_mock/{action}", self.mock_action)
        return app

    async def start(self, host, port, ssl_context=None):
        self.runner = web.AppRunner(self.app)
        await self.runner.setup()
        site = web.TCPSite(self.runner, host, port, ssl_context=ssl_context)
        await site.start()

    async def stop(self):
        if self.runner:
            await self.runner.cleanup()

    def settle(self):
        now = self.sim.now()
        for gen in list(self.generators.values()) + list(self.detached.values()):
            gen.settle(now)

    # ─── Middleware: slow answers, forced errors, the call log ───────────

    def _target(self, path):
        if path == TOKEN_PATH:
            return "token"
        if path.startswith(API):
            return "api"
        return None

    def _forced(self, target):
        f = self.fail
        if not f or f["target"] not in ("all", target):
            return None
        f["count"] -= 1
        if f["count"] <= 0:
            self.fail = None
        status = f["status"]
        headers = {"Retry-After": str(f["retry_after"])} if status == 429 else None
        if target == "token":
            error = "too_many_requests" if status == 429 else "server_error"
            body = {"error": error, "error_description": "Please try again later."}
            return json_response(body, status, headers)
        message = "Too Many Requests" if status == 429 else "The service is unavailable"
        return api_error(status, message, headers)

    @web.middleware
    async def middleware(self, request, handler):
        target = self._target(request.path)
        if target is None:
            return await handler(request)
        if self.slow and self.slow["target"] in ("all", target):
            await asyncio.sleep(self.slow["seconds"])
        resp = self._forced(target)
        if resp is None:
            self.settle()
            try:
                resp = await handler(request)
            except Answer as e:
                resp = e.resp
            except web.HTTPException as e:
                self._log(request, e.status)
                raise
        self._log(request, resp.status)
        return resp

    def _log(self, request, status):
        self.calls.append({"method": request.method, "path": request.path_qs, "status": status})
        del self.calls[:-CALL_LOG]

    # ─── Tokens ───────────────────────────────────────────────────────────

    def origin(self, request):
        if self.settings.get("public_url"):
            return self.settings["public_url"].rstrip("/")
        return f"{request.scheme}://{request.host}"

    def _jwt(self, claims):
        header = b64url(json.dumps({"alg": "HS256", "typ": "JWT", "kid": "mock"}).encode())
        body = b64url(json.dumps(claims, separators=(",", ":")).encode())
        sig = hmac.new(self.secret, f"{header}.{body}".encode(), hashlib.sha256).digest()
        return f"{header}.{body}.{b64url(sig)}"

    def _client_ok(self, request):
        auth = request.headers.get("Authorization", "")
        scheme, _, value = auth.partition(" ")
        if scheme.lower() != "basic":
            return False
        try:
            cid, _, secret = base64.b64decode(value.strip()).decode().partition(":")
        except ValueError:
            return False
        return hmac.compare_digest(cid, self.client_id) and hmac.compare_digest(
            secret, self.client_secret
        )

    def _issue(self, request, acct, scope):
        now = int(self.base.now())
        ttl = int(self.settings["access_ttl_s"])
        iss = f"{self.origin(request)}/oauth2/default"
        access = self._jwt(
            {
                "ver": 1,
                "jti": "AT." + secrets.token_urlsafe(16),
                "iss": iss,
                "aud": "api://default",
                "iat": now,
                "exp": now + ttl,
                "cid": self.client_id,
                "uid": acct.sub,
                "scp": scope.split(),
                "sub": acct.sub,
            }
        )
        self.access[access] = {"sub": acct.sub, "exp": now + ttl}
        id_token = self._jwt(
            {
                "sub": acct.sub,
                "email": acct.email,
                "ver": 1,
                "iss": iss,
                "aud": self.client_id,
                "iat": now,
                "exp": now + 3600,
                "jti": "ID." + secrets.token_urlsafe(16),
            }
        )
        body = {
            "token_type": "Bearer",
            "expires_in": ttl,
            "access_token": access,
            "scope": scope,
            "id_token": id_token,
        }
        if "offline_access" in scope.split():
            refresh = secrets.token_urlsafe(32)
            self.refresh[refresh] = {"sub": acct.sub, "scope": scope, "revoked": False}
            body["refresh_token"] = refresh
        return json_response(body, headers={"Cache-Control": "no-store", "Pragma": "no-cache"})

    def _scope(self, text, allowed=SCOPES):
        scopes = (text or "").split()
        if not scopes or any(s not in allowed for s in scopes):
            return None
        return " ".join(scopes)

    async def token(self, request):
        if not self._client_ok(request):
            return oauth_error(401, "invalid_client", "Client authentication failed.")
        if request.content_type != "application/x-www-form-urlencoded":
            return oauth_error(400, "invalid_request", "The request body must be form-encoded.")
        form = await request.post()
        grant = form.get("grant_type")
        if grant == "password":
            return self._password_grant(request, form)
        if grant == "refresh_token":
            return self._refresh_grant(request, form)
        return oauth_error(400, "unsupported_grant_type", f"Unsupported grant_type {grant!r}.")

    def _password_grant(self, request, form):
        scope = self._scope(form.get("scope"))
        if scope is None:
            return oauth_error(400, "invalid_scope", "The requested scope is not allowed.")
        acct = self.account_by_email(form.get("username"))
        password = form.get("password") or ""
        if acct is None or not hmac.compare_digest(password, acct.password):
            return oauth_error(400, "invalid_grant", "The credentials provided were invalid.")
        if acct.refuse:
            status = REFUSALS.get(acct.refuse, 400)
            return oauth_error(status, acct.refuse, "The sign-in was not allowed by policy.")
        return self._issue(request, acct, scope)

    def _refresh_grant(self, request, form):
        rec = self.refresh.get(form.get("refresh_token") or "")
        if rec is None or rec["revoked"]:
            return oauth_error(400, "invalid_grant", "The refresh token is invalid or expired.")
        scope = rec["scope"]
        if form.get("scope"):
            scope = self._scope(form.get("scope"), set(rec["scope"].split()))
            if scope is None:
                return oauth_error(400, "invalid_scope", "The requested scope is not allowed.")
        acct = self.account_by_sub(rec["sub"])
        if acct is None:
            return oauth_error(400, "invalid_grant", "The refresh token is invalid or expired.")
        rec["revoked"] = True
        return self._issue(request, acct, scope)

    # ─── API ──────────────────────────────────────────────────────────────

    def account_by_email(self, email):
        return next((a for a in self.accounts if a.email.lower() == (email or "").lower()), None)

    def account_by_sub(self, sub):
        return next((a for a in self.accounts if a.sub == sub), None)

    def _auth(self, request):
        """The signed-in account, or raise the service's refusal."""
        key = request.headers.get("ApiKey")
        if not key or not hmac.compare_digest(key, self.api_key):
            raise Answer(api_error(403, "Missing or invalid API key"))
        scheme, _, token = request.headers.get("Authorization", "").partition(" ")
        rec = self.access.get(token.strip()) if scheme.lower() == "bearer" else None
        acct = self.account_by_sub(rec["sub"]) if rec else None
        if acct is None or rec["exp"] <= self.base.now():
            raise Answer(api_error(401, "Unauthorized", {"WWW-Authenticate": "Bearer"}))
        return acct

    def _generator(self, request):
        acct = self._auth(request)
        try:
            gid = int(request.match_info["id"])
        except ValueError:
            gid = None
        gen = next((g for g in acct.generators if g.id == gid), None)
        if gen is None:
            raise Answer(api_error(404, "Device not found"))
        return gen

    async def _body(self, request):
        try:
            body = await request.json()
        except ValueError:
            body = None
        if not isinstance(body, dict):
            raise Answer(api_error(400, "The request body must be a JSON object"))
        return body

    async def me(self, request):
        return json_response(self._auth(request).me())

    async def homes(self, request):
        acct = self._auth(request)
        out = []
        for home in acct.homes:
            entry = copy.deepcopy(home)
            entry["devices"] = [g.summary() for g in acct.generators if g.home is home]
            out.append(entry)
        return json_response(out)

    async def notifications(self, request):
        acct = self._auth(request)
        notes = [n for g in acct.generators for n in g.notifications]
        return json_response(sorted(notes, key=lambda n: n["id"], reverse=True))

    async def device(self, request):
        gen = self._generator(request)
        host = request.query.get("sourceDeviceHost")
        if host is not None and host != gen.profile.get("deviceHost", "Oncue"):
            return api_error(404, "Device not found")
        return json_response(gen.record())

    async def alerts(self, request):
        return json_response(self._generator(request).alert_list())

    async def events(self, request):
        return json_response(self._generator(request).event_list())

    async def maintenance_notes(self, request):
        self._generator(request)
        return json_response([])

    async def _write(self, fn, *args):
        try:
            fn(*args)
        except Refused as e:
            return api_error(e.status, e.message)
        return web.Response(status=204)

    async def exercise_start(self, request):
        gen = self._generator(request)
        body = await self._body(request)
        return await self._write(gen.start_exercise, body.get("mode"))

    async def exercise_stop(self, request):
        return await self._write(self._generator(request).stop_exercise)

    async def exercise_put(self, request):
        gen = self._generator(request)
        return await self._write(gen.set_schedule, await self._body(request))

    async def exercise_delete(self, request):
        return await self._write(self._generator(request).delete_schedule)

    def _param_id(self, request):
        try:
            return int(request.match_info["param"])
        except ValueError:
            raise Answer(api_error(404, "Parameter not found")) from None

    async def set_value(self, request):
        gen = self._generator(request)
        body = await self._body(request)
        return await self._write(gen.set_value, self._param_id(request), body.get("value"))

    async def rename(self, request):
        gen = self._generator(request)
        body = await self._body(request)
        return await self._write(gen.rename, self._param_id(request), body.get("displayName"))

    # ─── Control API ──────────────────────────────────────────────────────

    ACTIONS = {
        "outage": "Utility power fails at a generator: {device}.",
        "restore": "Utility power returns: {device}.",
        "exercise_now": "Start the scheduled exercise now, as the controller would: {device}.",
        "fault": "A shutdown fault: {device, event?}. The engine stops and the status is Shutdown.",
        "warning": "A warning alert: {device, event?}.",
        "clear": "Clear a generator's alerts and any fault: {device}.",
        "battery": "Starting battery low or back to normal: {device, low}.",
        "switch": "Move the generator's switch: {device, position: Off|Auto|Manual}.",
        "online": "The generator's link to the service up or down: {device, online}.",
        "account": "Add or remove a generator on an account: {email, op: add|remove, device, "
        "profile?, home?, displayName?, serialNumber?}.",
        "slow": "Delay every answer: {seconds, target?: api|token|all}. seconds 0 turns it off.",
        "fail": "Answer the next N calls with an error: {status: 429|500|503, count, "
        "target?: api|token|all, retry_after?}.",
        "revoke": "Revoke refresh tokens: {email?}.",
        "expire": "Expire access tokens now: {email?}.",
        "password": "Change an account's password: {email, password}.",
        "refuse": "Refuse an account's sign-ins: {email, error: mfa_required|access_denied|null}.",
        "advance": "Jump the generators' clock: {seconds}.",
        "reset": "Put every generator and account back to the config, keeping tokens.",
    }

    async def mock_index(self, request):
        return json_response({"actions": self.ACTIONS})

    async def mock_state(self, request):
        self.settle()
        return json_response(
            {
                "fail": self.fail,
                "slow": self.slow,
                "generators": {str(i): g.state() for i, g in self.generators.items()},
                "detached": sorted(self.detached),
                "calls": self.calls,
            }
        )

    def _gen(self, body):
        gid = int(body.get("device", 0))
        gen = self.generators.get(gid) or self.detached.get(gid)
        if gen is None:
            raise ValueError(f"unknown device {gid}")
        return gen

    def _acct(self, body):
        acct = self.account_by_email(body.get("email"))
        if acct is None:
            raise ValueError(f"unknown account {body.get('email')!r}")
        return acct

    async def mock_action(self, request):
        action = request.match_info["action"]
        try:
            body = await request.json() if request.can_read_body else {}
        except ValueError:
            return json_response({"error": "body is not JSON"}, 400)
        handler = getattr(self, f"_do_{action}", None)
        if handler is None or action not in self.ACTIONS:
            return json_response({"error": f"unknown action {action!r}"}, 404)
        self.settle()
        try:
            result = handler(body or {})
        except (KeyError, ValueError, TypeError) as e:
            return json_response({"error": str(e)}, 400)
        return json_response({"ok": True, **(result or {})})

    def _do_outage(self, b):
        self._gen(b).utility_lost()

    def _do_restore(self, b):
        self._gen(b).utility_restored()

    def _do_exercise_now(self, b):
        self._gen(b).run_scheduled_now()

    def _do_fault(self, b):
        self._gen(b).raise_fault(b.get("event", "Overcrank"))

    def _do_warning(self, b):
        self._gen(b).raise_warning(b.get("event", "Parameter Value Abnormal"))

    def _do_clear(self, b):
        self._gen(b).clear_alerts()

    def _do_battery(self, b):
        self._gen(b).set_battery(bool(b.get("low", True)))

    def _do_switch(self, b):
        self._gen(b).set_switch(b["position"])

    def _do_online(self, b):
        self._gen(b).set_online(bool(b.get("online", True)))

    def _do_account(self, b):
        acct = self._acct(b)
        gid = int(b["device"])
        if b.get("op") == "remove":
            gen = next((g for g in acct.generators if g.id == gid), None)
            if gen is None:
                raise ValueError(f"device {gid} is not on {acct.email}")
            acct.generators.remove(gen)
            del self.generators[gid]
            self.detached[gid] = gen
        elif b.get("op") == "add":
            if gid in self.generators:
                raise ValueError(f"device {gid} is already on an account")
            gen = self.detached.pop(gid, None)
            if gen is not None:
                gen.owner = acct
                self.generators[gid] = gen
                acct.generators.append(gen)
            else:
                spec = {
                    "id": gid,
                    "profile": b["profile"],
                    "displayName": b.get("displayName", f"Demo Generator {gid}"),
                    "serialNumber": b.get("serialNumber", f"DEMO{gid:06d}"),
                }
                self._make_generator(spec, acct.homes[int(b.get("home", 0))], acct)
        else:
            raise ValueError("op must be add or remove")

    def _do_slow(self, b):
        seconds = float(b.get("seconds", 0))
        self.slow = {"seconds": seconds, "target": b.get("target", "all")} if seconds else None

    def _do_fail(self, b):
        status = b.get("status")
        if not status:
            self.fail = None
            return
        if int(status) not in (429, 500, 502, 503, 504):
            raise ValueError("status must be 429 or a 5xx")
        self.fail = {
            "status": int(status),
            "count": int(b.get("count", 1)),
            "target": b.get("target", "all"),
            "retry_after": int(b.get("retry_after", 30)),
        }

    def _subs(self, b):
        return {self._acct(b).sub} if b.get("email") else {a.sub for a in self.accounts}

    def _do_revoke(self, b):
        subs = self._subs(b)
        for rec in self.refresh.values():
            if rec["sub"] in subs:
                rec["revoked"] = True

    def _do_expire(self, b):
        subs = self._subs(b)
        now = self.base.now()
        for rec in self.access.values():
            if rec["sub"] in subs:
                rec["exp"] = min(rec["exp"], now)

    def _do_password(self, b):
        acct = self._acct(b)
        acct.password = b["password"]
        if self.settings["revoke_on_password_change"]:
            self._do_revoke({"email": acct.email})

    def _do_refuse(self, b):
        error = b.get("error")
        if error not in (None, *REFUSALS):
            raise ValueError(f"error must be one of {', '.join(REFUSALS)} or null")
        self._acct(b).refuse = error

    def _do_advance(self, b):
        self.sim.advance(float(b["seconds"]))
        self.settle()

    def _do_reset(self, b):
        self._load()

    # ─── Index ────────────────────────────────────────────────────────────

    async def index(self, request):
        rows = []
        for a in self.accounts:
            gens = ", ".join(
                f"{html.escape(g.name)} ({g.id}, {html.escape(g.profile['modelDisplayName'])})"
                for g in a.generators
            )
            rows.append(f"<li>{html.escape(a.email)}: {gens}</li>")
        text = (
            "<!doctype html><html><head><meta charset='utf-8'><title>Mock KOHLER</title></head>"
            "<body style='font-family:system-ui,sans-serif;max-width:40em;margin:3em auto'>"
            "<h1>Mock KOHLER generator cloud</h1><h2>Accounts</h2><ul>"
            + "".join(rows)
            + f"</ul><p>Token endpoint: <code>{TOKEN_PATH}</code>. API: <code>{API}</code>. "
            "Control API: <code>GET /_mock</code>.</p></body></html>"
        )
        return web.Response(text=text, content_type="text/html")


class Answer(Exception):
    """A finished response a helper raises; the middleware sends it."""

    def __init__(self, resp):
        super().__init__(resp.status)
        self.resp = resp
