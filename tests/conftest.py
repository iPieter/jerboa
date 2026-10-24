"""Shared fixtures for the security tests.

These tests need a Postgres with the repo's schema applied (see the project
README / run_tests.sh) and the app's two secrets in the environment:

    db_pass, flask_secret

and, optionally, db_user / db_name / db_host. The connection details default
to user ``postgres`` on ``127.0.0.1``, matching run_tests.sh.

The tests drive the app in-process: HTTP through Flask's test client and the
socket through Flask-SocketIO's test client (which speaks the same
python-socketio/Engine.IO stack the real clients use), so no external server
process is required.
"""
import base64
import os

import pytest

# libmagic for python-magic. The bundled wheel (pylibmagic) is used when the
# system library is absent; importing it is a no-op when it is not installed.
try:
    import pylibmagic  # noqa: F401
except ImportError:
    pass

os.environ.setdefault("db_pass", "testpasswd")
os.environ.setdefault("flask_secret", "test-secret-for-ci-only")

from werkzeug.security import generate_password_hash

from app import server as server_module
from app.database import Database


# username -> (plaintext password, state)
SEED_USERS = {
    "alice": ("pw-alice", "USER"),
    "bob": ("pw-bob", "USER"),
    "carol": ("pw-carol", "USER"),
    "admin": ("pw-admin", "ADMIN"),
    "pending": ("pw-pending", "REQUESTED"),
    "disabled": ("pw-disabled", "DISABLED"),
}


def _reset_schema(db):
    """Empties every table and recreates the fixed channels/membership.

    Channel 1 (General) is created by the migrations; we make a private
    channel 2 as well. alice and admin are members of the private channel;
    bob is not. Everyone is in General.
    """
    with db.cursor() as cur:
        cur.execute(
            "TRUNCATE messages, channels_users, active_logins, emojis, files, "
            "channels, users RESTART IDENTITY CASCADE"
        )
        for username, (password, state) in SEED_USERS.items():
            cur.execute(
                "INSERT INTO users (username, password, display_name, first_name, "
                "state, email) VALUES (%s, %s, %s, %s, %s, %s)",
                (
                    username,
                    generate_password_hash(password),
                    username.title(),
                    username.title(),
                    state,
                    "{}@example.com".format(username),
                ),
            )
        cur.execute(
            "INSERT INTO channels (id, name, type) VALUES (1, 'General', 'DEFAULT'), "
            "(2, 'secret', 'PRIVATE')"
        )
        cur.execute("SELECT setval('channels_id_seq', 2)")
        # General: everyone. Private channel 2: alice, admin only.
        cur.execute("SELECT id, username FROM users")
        rows = cur.fetchall()
        for uid, username in rows:
            cur.execute(
                "INSERT INTO channels_users (channel_id, user_id, joined) "
                "VALUES (1, %s, 0)",
                (uid,),
            )
            if username in ("alice", "admin"):
                cur.execute(
                    "INSERT INTO channels_users (channel_id, user_id, joined) "
                    "VALUES (2, %s, 0)",
                    (uid,),
                )


@pytest.fixture(scope="session")
def _seed_db():
    db = Database(os.environ["db_pass"])
    _reset_schema(db)
    return db


@pytest.fixture
def db(_seed_db):
    # Re-seed before each test so state never leaks between tests.
    _reset_schema(_seed_db)
    return _seed_db


@pytest.fixture
def server(db):
    return server_module


@pytest.fixture
def client(server):
    server.app.config["TESTING"] = True
    return server.app.test_client()


def basic_auth_header(username):
    password = SEED_USERS[username][0]
    raw = "{}:{}".format(username, password).encode()
    return {"Authorization": "Basic " + base64.b64encode(raw).decode()}


@pytest.fixture
def tokens(server, client):
    """A valid session JWT for each active user, via the real login flow."""
    out = {}
    for username, (_password, state) in SEED_USERS.items():
        resp = client.get("/login", headers=basic_auth_header(username))
        if resp.status_code == 200:
            out[username] = resp.get_json()["token"]
    return out


def socket_client(server, token=None):
    """A connected Flask-SocketIO test client, optionally joined to its rooms."""
    sio = server.socketio.test_client(server.app)
    assert sio.is_connected()
    sio.get_received()  # drain the connect handshake
    if token is not None:
        sio.emit("join_rooms", token)
    return sio
