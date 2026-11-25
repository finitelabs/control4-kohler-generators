import base64
import copy
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from mock_kohler import ROOT  # noqa: E402
from mock_kohler.cloud import API, TOKEN_PATH, Cloud  # noqa: E402
from mock_kohler.clock import FakeClock  # noqa: E402

DEMO = json.loads((ROOT / "instances" / "demo.json").read_text())
SINGLE = json.loads((ROOT / "instances" / "single.json").read_text())
OFFLINE = json.loads((ROOT / "instances" / "offline.json").read_text())
EMAIL, PASSWORD = "demo@example.com", "demo-password-1"
SCOPE = "openid profile offline_access email"
API_KEY = "mock-api-key"
BLUE, LIQUID, REDGREEN, OFFLINE_ID = 58001, 58002, 58003, 58004


def basic(client_id="mock-client", secret="mock-client-secret"):
    return "Basic " + base64.b64encode(f"{client_id}:{secret}".encode()).decode()


@pytest.fixture
def clock():
    return FakeClock()


@pytest.fixture
def make_cloud(aiohttp_client, clock):
    """A cloud on the aiohttp test server, on the fake clock."""

    async def make(config=None, settings=None, speed=1.0):
        cfg = copy.deepcopy(config or DEMO)
        cfg.setdefault("settings", {}).update(settings or {})
        cloud = Cloud(cfg, clock=clock, speed=speed)
        client = await aiohttp_client(cloud.app)
        return cloud, client

    return make


async def token_call(client, data, auth=None):
    return await client.post(
        TOKEN_PATH, data=data, headers={"Authorization": auth if auth is not None else basic()}
    )


async def sign_in(client, email=EMAIL, password=PASSWORD, scope=SCOPE):
    resp = await token_call(
        client, {"grant_type": "password", "username": email, "password": password, "scope": scope}
    )
    assert resp.status == 200, await resp.text()
    return await resp.json()


def headers(token, key=API_KEY):
    out = {"Authorization": f"bearer {token}"}
    if key is not None:
        out["ApiKey"] = key
    return out


class Api:
    """A signed-in client for the homeowner API."""

    def __init__(self, client, token):
        self.client = client
        self.token = token

    async def call(self, method, path, body=None):
        kwargs = {"headers": headers(self.token)}
        if body is not None:
            kwargs["json"] = body
        return await self.client.request(method, API + path, **kwargs)

    async def get(self, path):
        resp = await self.call("GET", path)
        assert resp.status == 200, f"{path}: {resp.status} {await resp.text()}"
        return await resp.json()

    async def record(self, gid):
        return await self.get(f"/devices/{gid}?sourceDeviceHost=Oncue")


@pytest.fixture
def signed_in(make_cloud):
    async def make(config=None, settings=None):
        cloud, client = await make_cloud(config, settings)
        tokens = await sign_in(client)
        return cloud, client, Api(client, tokens["access_token"])

    return make


async def control(client, action, **body):
    resp = await client.post(f"/_mock/{action}", json=body)
    assert resp.status == 200, await resp.text()
    return await resp.json()


def events_named(events, name):
    return [e for e in events if e["event"] == name]
