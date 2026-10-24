"""Regression tests for the October 2026 hardening.

Each test pins behaviour that is wrong on the pre-fix code and correct after
it. The HTTP surface is exercised through Flask's test client and the socket
surface through Flask-SocketIO's test client.
"""
import json
import os

import pytest

from conftest import basic_auth_header, socket_client, SEED_USERS

from app.database import Database, connection_kwargs, PUBLIC_USER_COLUMNS


# --------------------------------------------------------------------------
# 1. Authentication / account state and admin-only status changes
# --------------------------------------------------------------------------


def test_requested_user_cannot_use_basic_auth(client):
    # REQUESTED accounts (anyone who just signed up) must be rejected.
    resp = client.get("/", headers=basic_auth_header("pending"))
    assert resp.status_code == 401


def test_disabled_user_cannot_use_basic_auth(client):
    resp = client.get("/", headers=basic_auth_header("disabled"))
    assert resp.status_code == 401


def test_active_user_can_use_basic_auth(client):
    resp = client.get("/", headers=basic_auth_header("alice"))
    assert resp.status_code == 200


def test_status_change_requires_admin(client):
    # A normal user must not be able to promote anyone (incl. themselves).
    resp = client.post(
        "/users/status",
        headers=basic_auth_header("alice"),
        data={"username": "alice", "status": "ADMIN"},
    )
    assert resp.status_code == 403
    assert Database(os.environ["db_pass"]).get_public_user("alice")["state"] == "USER"


def test_status_change_allowed_for_admin(client, db):
    resp = client.post(
        "/users/status",
        headers=basic_auth_header("admin"),
        data={"username": "bob", "status": "ADMIN"},
    )
    assert resp.status_code == 200
    assert db.get_public_user("bob")["state"] == "ADMIN"


def test_status_change_rejects_unknown_state(client):
    resp = client.post(
        "/users/status",
        headers=basic_auth_header("admin"),
        data={"username": "bob", "status": "SUPERADMIN"},
    )
    assert resp.status_code == 400


# --------------------------------------------------------------------------
# 2. Emoji path traversal + SSRF
# --------------------------------------------------------------------------


def test_emoji_name_rejects_traversal(server):
    assert server._safe_emoji_name("../../etc/passwd") is None
    assert server._safe_emoji_name("/etc/passwd") is None
    assert server._safe_emoji_name("a/b") is None
    assert server._safe_emoji_name(".") is None
    assert server._safe_emoji_name("") is None
    # Ordinary emoji names are preserved unchanged.
    assert server._safe_emoji_name("+1") == "+1"
    assert server._safe_emoji_name("party_parrot") == "party_parrot"


def test_emoji_upload_rejects_traversal(client, tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    data = {
        "name": "../pwned",
        "file": (__import__("io").BytesIO(b"x"), "e.png"),
    }
    resp = client.post(
        "/emoji",
        headers=basic_auth_header("alice"),
        data=data,
        content_type="multipart/form-data",
    )
    assert resp.status_code == 400
    assert not os.path.exists(os.path.join(str(tmp_path), "pwned"))


def test_ssrf_blocks_file_scheme(server, tmp_path):
    dest = str(tmp_path / "out")
    with pytest.raises(ValueError):
        server._download_remote_image("file:///etc/passwd", dest)
    assert not os.path.exists(dest)


def test_ssrf_blocks_localhost(server, tmp_path):
    dest = str(tmp_path / "out")
    with pytest.raises(ValueError):
        server._download_remote_image("http://127.0.0.1:5432/", dest)
    with pytest.raises(ValueError):
        server._download_remote_image("http://localhost/secrets", dest)
    assert not os.path.exists(dest)


# --------------------------------------------------------------------------
# 3. Password hashes never leave the server
# --------------------------------------------------------------------------


def test_users_list_has_no_password(client):
    resp = client.get("/users", headers=basic_auth_header("alice"))
    assert resp.status_code == 200
    for user in json.loads(resp.data):
        assert "password" not in user


def test_user_self_has_no_password(client):
    resp = client.get("/user", headers=basic_auth_header("alice"))
    assert resp.status_code == 200
    assert "password" not in json.loads(resp.data)


def test_user_by_name_has_no_password_or_private_fields(client):
    resp = client.get("/user/bob", headers=basic_auth_header("alice"))
    assert resp.status_code == 200
    body = json.loads(resp.data)
    assert "password" not in body
    # Another user's private columns are not exposed.
    assert "email" not in body


def test_public_columns_exclude_password():
    assert "password" not in PUBLIC_USER_COLUMNS


# --------------------------------------------------------------------------
# 4. Channel membership checks (HTTP)
# --------------------------------------------------------------------------


def test_messages_requires_membership(client):
    # bob is not a member of the private channel 2.
    resp = client.get(
        "/messages?channel=2&initial_msg_id=0", headers=basic_auth_header("bob")
    )
    assert resp.status_code == 403


def test_messages_allowed_for_member(client):
    resp = client.get(
        "/messages?channel=2&initial_msg_id=0", headers=basic_auth_header("alice")
    )
    assert resp.status_code == 200


def test_search_requires_membership(client):
    resp = client.post(
        "/channels/search",
        headers=basic_auth_header("bob"),
        data={"channel_id": "2", "query": "hello"},
    )
    assert resp.status_code == 403


def test_add_user_requires_membership(client, db):
    # bob (not a member of 2) must not be able to add carol to the private channel.
    resp = client.post(
        "/channels/add_user",
        headers=basic_auth_header("bob"),
        data={"channel_id": "2", "username": "carol"},
    )
    assert resp.status_code == 403
    assert not db.is_channel_member("2", "carol")


def test_add_user_allowed_for_member(client, db):
    resp = client.post(
        "/channels/add_user",
        headers=basic_auth_header("alice"),
        data={"channel_id": "2", "username": "carol"},
    )
    assert resp.status_code == 200
    assert db.is_channel_member("2", "carol")


# --------------------------------------------------------------------------
# 5. Unauthenticated / unauthorized deletes
# --------------------------------------------------------------------------


def test_delete_all_emoji_requires_auth(client):
    resp = client.delete("/emojis")
    assert resp.status_code == 401


def test_delete_all_emoji_requires_admin(client):
    resp = client.delete("/emojis", headers=basic_auth_header("alice"))
    assert resp.status_code == 403


def test_delete_single_emoji_requires_auth(client):
    resp = client.delete("/emoji/anything")
    assert resp.status_code == 401


def test_delete_emoji_allowed_for_admin(client, db, tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    db.insert_emoji("alice", "grin", "grin", 0)
    resp = client.delete("/emoji/grin", headers=basic_auth_header("admin"))
    assert resp.status_code == 200
    assert db.get_emoji("grin") is None


# --------------------------------------------------------------------------
# 6. Session handling
# --------------------------------------------------------------------------


def test_delete_session_requires_ownership(client, db, tokens):
    # A session that belongs to alice must not be killable by bob.
    alice_sessions = db.get_sessions("alice")
    assert alice_sessions
    sid = alice_sessions[0]["id"]
    resp = client.delete(
        "/users/sessions/{}".format(sid), headers=basic_auth_header("bob")
    )
    assert resp.status_code == 403
    assert db.get_session(sid)["active"] in (1, True)


def test_delete_own_session_allowed(client, db, tokens):
    alice_sessions = db.get_sessions("alice")
    sid = alice_sessions[0]["id"]
    resp = client.delete(
        "/users/sessions/{}".format(sid), headers=basic_auth_header("alice")
    )
    assert resp.status_code == 200
    assert db.get_session(sid)["active"] in (0, False)


def test_admin_can_delete_any_session(client, db, tokens):
    alice_sessions = db.get_sessions("alice")
    sid = alice_sessions[0]["id"]
    resp = client.delete(
        "/users/sessions/{}".format(sid), headers=basic_auth_header("admin")
    )
    assert resp.status_code == 200


# --------------------------------------------------------------------------
# 7. Socket authentication and behaviour
# --------------------------------------------------------------------------


def _text_msg(token, channel, text, nonce="n1"):
    return json.dumps(
        {
            "sender": token,
            "message_type": "TEXT_MESSAGE",
            "channel": channel,
            "message": text,
            "sent_time": 0,
            "nonce": nonce,
            "signature": "na",
        }
    )


def test_socket_connect_does_not_autojoin_general(server, db):
    # An unauthenticated socket must not be put in room "1": a member posting
    # to General should not reach a socket that never authenticated.
    listener = socket_client(server)  # no token -> no rooms
    alice_token = _login_token(server, "alice")
    sender = socket_client(server, alice_token)

    sender.emit("msg", _text_msg(alice_token, "1", "hello general"))
    received = listener.get_received()
    assert received == []
    sender.disconnect()
    listener.disconnect()


def test_socket_rejects_unauthenticated_post(server, db):
    sio = socket_client(server)  # connected but never authenticated
    sio.emit("msg", _text_msg("not-a-real-token", "1", "hi"))
    received = sio.get_received()
    names = [r["name"] for r in received]
    assert "msg" not in names
    assert "error" in names
    sio.disconnect()


def test_socket_non_member_cannot_post(server, db):
    bob_token = _login_token(server, "bob")
    sio = socket_client(server, bob_token)
    sio.get_received()
    sio.emit("msg", _text_msg(bob_token, "2", "sneaking in"))
    received = sio.get_received()
    assert [r["name"] for r in received if r["name"] == "msg"] == []
    assert db.get_messages("2") == []
    sio.disconnect()


def test_socket_message_delivered_to_room_member(server, db):
    alice_token = _login_token(server, "alice")
    sender = socket_client(server, alice_token)
    listener = socket_client(server, alice_token)
    sender.get_received()
    listener.get_received()

    sender.emit("msg", _text_msg(alice_token, "1", "room hello", nonce="xyz"))
    delivered = listener.get_received()
    msgs = [r for r in delivered if r["name"] == "msg"]
    assert msgs, "message was not delivered to another member of the room"
    payload = msgs[0]["args"][0]
    assert payload["sender"] == "alice"
    assert payload["nonce"] == "xyz"
    assert payload["message"] == "room hello"
    sender.disconnect()
    listener.disconnect()


def test_socket_room_normalisation_string_and_int(server, db):
    """A join (int ids) and an emit must land in the same room regardless of
    whether the client sends the channel as a string or an int."""
    alice_token = _login_token(server, "alice")
    listener = socket_client(server, alice_token)
    sender = socket_client(server, alice_token)
    listener.get_received()

    # Web client sends the channel as a string, iOS as an int. Both must work.
    sender.emit("msg", _text_msg(alice_token, 1, "as int"))
    delivered = [r for r in listener.get_received() if r["name"] == "msg"]
    assert delivered, "int channel id did not reach the string-joined room"
    sender.disconnect()
    listener.disconnect()


def test_socket_join_rooms_expired_token_emits_error(server, monkeypatch):
    from itsdangerous import SignatureExpired

    def boom(_token):
        raise SignatureExpired("expired")

    monkeypatch.setattr(server.jws, "loads", boom)
    sio = socket_client(server)
    sio.emit("join_rooms", "whatever")
    received = sio.get_received()
    assert any(
        r["name"] == "error" and r["args"][0] == "Signature expired"
        for r in received
    )
    sio.disconnect()


def test_socket_disabled_user_cannot_post(server, db):
    # Give the disabled user an active session, then disable mid-session.
    token = _login_token(server, "alice")
    db.set_user_status("alice", "DISABLED")
    sio = socket_client(server)
    sio.emit("msg", _text_msg(token, "1", "still here"))
    received = sio.get_received()
    assert [r for r in received if r["name"] == "msg"] == []
    sio.disconnect()


def test_socket_revoked_session_cannot_post(server, db):
    token = _login_token(server, "alice")
    for s in db.get_sessions("alice"):
        db.disable_session(s["id"])
    sio = socket_client(server)
    sio.emit("msg", _text_msg(token, "1", "revoked"))
    received = sio.get_received()
    assert [r for r in received if r["name"] == "msg"] == []
    sio.disconnect()


# --------------------------------------------------------------------------
# 8. Forgeable shares
# --------------------------------------------------------------------------


def test_share_source_is_looked_up_server_side(server, db):
    alice_token = _login_token(server, "alice")
    sender = socket_client(server, alice_token)
    sender.get_received()

    # alice posts a real message in General.
    sender.emit("msg", _text_msg(alice_token, "1", "the real quote", nonce="a"))
    real = [r for r in sender.get_received() if r["name"] == "msg"][0]["args"][0]
    real_id = real["id"]

    # Now alice shares it but lies about the sender and text in `source`.
    forged = json.dumps(
        {
            "sender": alice_token,
            "message_type": "SHARE_MESSAGE",
            "channel": "1",
            "message": {
                "message": "look what admin said",
                "source": {
                    "id": real_id,
                    "sender": "admin",
                    "message_type": "TEXT_MESSAGE",
                    "message": "I hereby resign",
                    "sent_time": 0,
                    "previous_message": None,
                    "channel": "1",
                },
            },
            "nonce": "share1",
            "sent_time": 0,
            "signature": "na",
        }
    )
    sender.emit("msg", forged)
    out = [r for r in sender.get_received() if r["name"] == "msg"][0]["args"][0]
    source = out["message"]["source"]
    # The server rebuilt the quote from the stored message, not the client lie.
    assert source["sender"] == "alice"
    assert source["message"] == "the real quote"
    assert source["id"] == real_id
    # Shape preserved for the clients.
    assert set(source.keys()) == {
        "id",
        "sender",
        "message_type",
        "message",
        "sent_time",
        "previous_message",
        "channel",
    }
    sender.disconnect()


def test_share_unknown_source_rejected(server, db):
    alice_token = _login_token(server, "alice")
    sio = socket_client(server, alice_token)
    sio.get_received()
    forged = json.dumps(
        {
            "sender": alice_token,
            "message_type": "SHARE_MESSAGE",
            "channel": "1",
            "message": {"message": "x", "source": {"id": 999999, "sender": "admin"}},
            "nonce": "s",
            "sent_time": 0,
            "signature": "na",
        }
    )
    sio.emit("msg", forged)
    received = sio.get_received()
    assert [r for r in received if r["name"] == "msg"] == []
    assert any(r["name"] == "error" for r in received)
    sio.disconnect()


# --------------------------------------------------------------------------
# 10. /files inline serving hardening
# --------------------------------------------------------------------------


def _store_file(db, tmp_path, identifier, full_name, content, mime):
    os.makedirs(os.path.join(str(tmp_path), "data"), exist_ok=True)
    with open(
        os.path.join(str(tmp_path), "data", identifier + "_" + full_name), "wb"
    ) as fp:
        fp.write(content)
    db.insert_file(identifier, "alice", mime, len(content), full_name)


def test_files_html_is_never_inline(client, db, tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    _store_file(
        db, tmp_path, "htmlid", "evil.html", b"<script>alert(1)</script>", "text/html"
    )
    resp = client.get("/files?f=htmlid&show=1")
    assert resp.status_code == 200
    assert resp.headers["X-Content-Type-Options"] == "nosniff"
    assert resp.headers["Content-disposition"].startswith("attachment")


def test_files_svg_is_never_inline(client, db, tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    _store_file(db, tmp_path, "svgid", "x.svg", b"<svg></svg>", "image/svg+xml")
    resp = client.get("/files?f=svgid&show=1")
    assert resp.headers["Content-disposition"].startswith("attachment")
    assert resp.headers["X-Content-Type-Options"] == "nosniff"


def test_files_image_can_be_inline(client, db, tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    _store_file(db, tmp_path, "pngid", "p.png", b"\x89PNG\r\n", "image/png")
    resp = client.get("/files?f=pngid&show=1")
    assert resp.headers["Content-disposition"].startswith("inline")
    assert resp.headers["X-Content-Type-Options"] == "nosniff"


# --------------------------------------------------------------------------
# 12. Token is not printed / leaked in the msg handler
# --------------------------------------------------------------------------


def test_msg_handler_does_not_print_token(server, db, capsys):
    alice_token = _login_token(server, "alice")
    sio = socket_client(server, alice_token)
    sio.get_received()
    capsys.readouterr()  # clear
    sio.emit("msg", _text_msg(alice_token, "1", "no leaks please"))
    sio.get_received()
    captured = capsys.readouterr()
    assert alice_token not in captured.out
    assert alice_token not in captured.err
    sio.disconnect()


# --------------------------------------------------------------------------
# DB robustness and configurability
# --------------------------------------------------------------------------


def test_connection_kwargs_default_matches_today():
    kw = connection_kwargs("secret", {})
    assert kw == {"user": "postgres", "password": "secret", "host": "127.0.0.1"}
    assert "dbname" not in kw


def test_connection_kwargs_from_environment():
    kw = connection_kwargs(
        "secret",
        {"db_user": "jerboa_app", "db_name": "jerboa", "db_host": "db.internal"},
    )
    assert kw == {
        "user": "jerboa_app",
        "password": "secret",
        "host": "db.internal",
        "dbname": "jerboa",
    }


def test_connection_survives_a_bad_query(db):
    # A failing statement must not poison the connection for the next caller.
    with pytest.raises(Exception):
        with db.cursor() as cur:
            cur.execute("SELECT * FROM table_that_does_not_exist")
    # The pool is still usable.
    assert db.get_public_user("alice")["username"] == "alice"


def test_search_tolerates_trailing_space(client):
    # websearch_to_tsquery accepts free text; a trailing space used to blow up
    # the old " & " -> to_tsquery rewrite with a syntax error (HTTP 500).
    resp = client.post(
        "/channels/search",
        headers=basic_auth_header("alice"),
        data={"channel_id": "1", "query": "hello "},
    )
    assert resp.status_code == 200


def test_search_tolerates_special_characters(client):
    resp = client.post(
        "/channels/search",
        headers=basic_auth_header("alice"),
        data={"channel_id": "1", "query": "a & b | !"},
    )
    assert resp.status_code == 200


# --------------------------------------------------------------------------
# helper
# --------------------------------------------------------------------------


def _login_token(server, username):
    server.app.config["TESTING"] = True
    c = server.app.test_client()
    resp = c.get("/login", headers=basic_auth_header(username))
    assert resp.status_code == 200, "login failed for {}".format(username)
    return resp.get_json()["token"]
