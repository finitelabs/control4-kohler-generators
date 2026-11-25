import base64
import json

from conftest import (
    API,
    API_KEY,
    EMAIL,
    OFFLINE,
    PASSWORD,
    SCOPE,
    TOKEN_PATH,
    basic,
    control,
    headers,
    sign_in,
    token_call,
)


def claims(jwt):
    body = jwt.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))


async def me_status(client, token, key=API_KEY):
    resp = await client.get(f"{API}/homeowner/me", headers=headers(token, key))
    return resp.status


async def test_password_grant(make_cloud):
    _, client = await make_cloud()
    tok = await sign_in(client)
    assert tok["token_type"] == "Bearer"
    assert tok["expires_in"] == 3600
    assert tok["scope"] == SCOPE
    assert tok["refresh_token"] and tok["id_token"]
    c = claims(tok["access_token"])
    assert c["sub"] == "00umockdemo0000001"
    assert c["exp"] - c["iat"] == 3600
    assert claims(tok["id_token"])["sub"] == c["sub"]
    assert await me_status(client, tok["access_token"]) == 200


async def test_sub_is_stable_across_sign_ins(make_cloud):
    _, client = await make_cloud()
    a, b = await sign_in(client), await sign_in(client)
    assert a["access_token"] != b["access_token"]
    assert claims(a["access_token"])["sub"] == claims(b["access_token"])["sub"]


async def test_username_is_case_insensitive(make_cloud):
    _, client = await make_cloud()
    await sign_in(client, email=EMAIL.upper())


async def test_no_offline_access_no_refresh_token(make_cloud):
    _, client = await make_cloud()
    tok = await sign_in(client, scope="openid profile email")
    assert "refresh_token" not in tok


async def test_refresh_rotates_and_old_token_stops_working(make_cloud):
    _, client = await make_cloud()
    first = await sign_in(client)
    resp = await token_call(
        client, {"grant_type": "refresh_token", "refresh_token": first["refresh_token"]}
    )
    assert resp.status == 200
    second = await resp.json()
    assert second["refresh_token"] != first["refresh_token"]
    assert second["scope"] == SCOPE
    assert await me_status(client, second["access_token"]) == 200
    again = await token_call(
        client, {"grant_type": "refresh_token", "refresh_token": first["refresh_token"]}
    )
    assert again.status == 400
    assert (await again.json())["error"] == "invalid_grant"
    newest = await token_call(
        client,
        {
            "grant_type": "refresh_token",
            "refresh_token": second["refresh_token"],
            "scope": SCOPE,
        },
    )
    assert newest.status == 200


async def test_refresh_cannot_widen_scope(make_cloud):
    _, client = await make_cloud()
    tok = await sign_in(client, scope="openid offline_access")
    resp = await token_call(
        client,
        {
            "grant_type": "refresh_token",
            "refresh_token": tok["refresh_token"],
            "scope": SCOPE,
        },
    )
    assert resp.status == 400
    assert (await resp.json())["error"] == "invalid_scope"


async def test_access_token_expires(make_cloud, clock):
    _, client = await make_cloud(settings={"access_ttl_s": 60})
    tok = await sign_in(client)
    assert tok["expires_in"] == 60
    clock.advance(59)
    assert await me_status(client, tok["access_token"]) == 200
    clock.advance(1)
    resp = await client.get(f"{API}/homeowner/me", headers=headers(tok["access_token"]))
    assert resp.status == 401
    assert resp.headers["WWW-Authenticate"] == "Bearer"


async def test_bad_password_and_unknown_user(make_cloud):
    _, client = await make_cloud()
    for user, pw in ((EMAIL, "wrong"), ("nobody@example.com", PASSWORD)):
        resp = await token_call(
            client,
            {
                "grant_type": "password",
                "username": user,
                "password": pw,
                "scope": SCOPE,
            },
        )
        assert resp.status == 400
        body = await resp.json()
        assert body["error"] == "invalid_grant"
        assert body["error_description"]


async def test_refused_sign_in(make_cloud):
    cfg = json.loads(json.dumps(OFFLINE))
    cfg["accounts"][0]["refuse"] = "mfa_required"
    _, client = await make_cloud(cfg)
    data = {
        "grant_type": "password",
        "username": EMAIL,
        "password": PASSWORD,
        "scope": SCOPE,
    }
    resp = await token_call(client, data)
    assert resp.status == 400
    assert (await resp.json())["error"] == "mfa_required"
    # A wrong password is still a wrong password, not a refusal.
    bad = await token_call(client, {**data, "password": "wrong"})
    assert (await bad.json())["error"] == "invalid_grant"
    await control(client, "refuse", email=EMAIL, error="access_denied")
    resp = await token_call(client, data)
    assert resp.status == 401
    assert (await resp.json())["error"] == "access_denied"
    await control(client, "refuse", email=EMAIL, error=None)
    await sign_in(client)


async def test_client_authentication(make_cloud):
    _, client = await make_cloud()
    data = {
        "grant_type": "password",
        "username": EMAIL,
        "password": PASSWORD,
        "scope": SCOPE,
    }
    for auth in (
        "",
        basic("other-client"),
        basic(secret="wrong"),
        "Bearer x",
        "Basic !!!",
    ):
        resp = await token_call(client, data, auth=auth)
        assert resp.status == 401, auth
        assert (await resp.json())["error"] == "invalid_client"


async def test_token_request_shape(make_cloud):
    _, client = await make_cloud()
    resp = await client.post(
        TOKEN_PATH,
        json={"grant_type": "password", "username": EMAIL, "password": PASSWORD},
        headers={"Authorization": basic()},
    )
    assert resp.status == 400
    assert (await resp.json())["error"] == "invalid_request"
    resp = await token_call(client, {"grant_type": "client_credentials"})
    assert (await resp.json())["error"] == "unsupported_grant_type"
    resp = await token_call(
        client,
        {
            "grant_type": "password",
            "username": EMAIL,
            "password": PASSWORD,
            "scope": "admin",
        },
    )
    assert (await resp.json())["error"] == "invalid_scope"


async def test_api_key_and_bearer_checks(make_cloud):
    _, client = await make_cloud()
    tok = (await sign_in(client))["access_token"]
    assert await me_status(client, tok, key=None) == 403
    assert await me_status(client, tok, key="wrong-key") == 403
    # Header names and the scheme are case-insensitive.
    resp = await client.get(
        f"{API}/homeowner/me",
        headers={"authorization": f"BEARER {tok}", "apikey": API_KEY},
    )
    assert resp.status == 200
    for auth in (
        {},
        {"Authorization": "bearer nonsense"},
        {"Authorization": f"Basic {tok}"},
    ):
        resp = await client.get(
            f"{API}/homeowner/me", headers={"ApiKey": API_KEY, **auth}
        )
        assert resp.status == 401, auth
