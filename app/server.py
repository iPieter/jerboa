import os
import shutil
import ipaddress
import socket
from flask import Flask, g, request, abort, Response, jsonify, send_file
from flask_cors import CORS
import pandas as pd
import simplejson as json
import time
from flask_httpauth import HTTPBasicAuth, HTTPTokenAuth, MultiAuth
from werkzeug.utils import secure_filename
from werkzeug.security import generate_password_hash, check_password_hash, safe_str_cmp
import pika
from itsdangerous import TimedJSONWebSignatureSerializer as JWS
from itsdangerous import SignatureExpired, BadSignature
import secrets
from flask_socketio import SocketIO
from flask_socketio import send, emit, join_room
import magic
import urllib.request
import urllib.parse
import urllib.error
from app.database import Database
from datetime import datetime

assert "db_pass" in os.environ
assert "flask_secret" in os.environ

from flask_socketio import SocketIO

app = Flask(__name__)
CORS(app)
app.config["SECRET_KEY"] = os.environ["flask_secret"]
app.config["EXPIRES"] = 7 * 24 * 3600
socketio = SocketIO(app, cors_allowed_origins="*", engineiologger=True, logger=True, ping_timeout=10, ping_interval=5)
jws = JWS(app.config["SECRET_KEY"], expires_in=app.config["EXPIRES"])
database = Database(os.environ["db_pass"])

basic_auth = HTTPBasicAuth()
token_auth = HTTPTokenAuth("Bearer")
multi_auth = MultiAuth(basic_auth, token_auth)

# States that are allowed to use the API. REQUESTED (awaiting approval) and
# DISABLED accounts must not be able to authenticate.
ACTIVE_STATES = ("USER", "ADMIN")

# Stored mimetypes we are willing to serve inline. Everything else (notably
# text/html and image/svg+xml, which can carry script) is forced to download.
INLINE_MIME_TYPES = frozenset(
    [
        "image/png",
        "image/jpeg",
        "image/gif",
        "image/webp",
        "image/bmp",
        "image/x-icon",
        "image/vnd.microsoft.icon",
        "image/tiff",
        "application/pdf",
    ]
)


def _is_active_user(user):
    return bool(user) and user.get("state") in ACTIVE_STATES


def current_user_is_admin():
    """True if the authenticated user (``g.user``) is an ADMIN."""
    if not getattr(g, "user", None):
        return False
    user = database.get_public_user(g.user)
    return bool(user) and user.get("state") == "ADMIN"


def _safe_emoji_name(name):
    """Returns ``name`` if it is a safe single filename inside ``emojis/``.

    Rejects anything that would let a name escape the emoji directory (path
    separators, ``..``, leading dots, absolute paths). Keeps names like
    ``+1`` or ``party_parrot`` untouched so existing emoji keep working.
    """
    if not name or "/" in name or "\\" in name or "\0" in name:
        return None
    if name in (".", "..") or name.startswith("."):
        return None
    emoji_dir = os.path.abspath("emojis")
    resolved = os.path.abspath(os.path.join(emoji_dir, name))
    if os.path.dirname(resolved) != emoji_dir:
        return None
    return name


def _host_is_public(host):
    """True only if every address a host resolves to is a public IP.

    Blocks loopback, private, link-local, reserved and multicast ranges so a
    user-supplied URL cannot reach the server itself or the internal network.
    """
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror:
        return False
    for info in infos:
        try:
            ip = ipaddress.ip_address(info[4][0])
        except ValueError:
            return False
        if (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_reserved
            or ip.is_multicast
            or ip.is_unspecified
        ):
            return False
    return True


def _download_remote_image(url, dest):
    """Fetches an http(s) URL from a public host into ``dest``.

    Only http/https are handled (so ``file://``/``ftp://`` cannot be read) and
    the host must resolve to a public address (so localhost and the internal
    network are unreachable). Redirects are not followed, which removes the
    redirect-to-internal bypass. Raises ``ValueError`` if the URL is not
    allowed.
    """
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError("unsupported URL scheme")
    if not parsed.hostname or not _host_is_public(parsed.hostname):
        raise ValueError("host not allowed")

    # An opener built from only HTTP(S) handlers: no FileHandler/FTPHandler and
    # no redirect handler, so nothing but a direct http(s) 200 can be read.
    opener = urllib.request.OpenerDirector()
    opener.add_handler(urllib.request.ProxyHandler({}))
    opener.add_handler(urllib.request.HTTPHandler())
    opener.add_handler(urllib.request.HTTPSHandler())
    opener.add_handler(urllib.request.HTTPErrorProcessor())

    with opener.open(url, timeout=10) as response:
        if getattr(response, "status", 200) != 200:
            raise ValueError("unexpected response status")
        with open(dest, "wb") as fp:
            shutil.copyfileobj(response, fp, 65536)


@socketio.on("connect")
def test_connect():
    # Do NOT join any room here: the socket is unauthenticated at this point.
    # The client authenticates and joins its channels via the `join_rooms`
    # event once it has a token.
    print("connected")


@socketio.on("disconnect")
def test_disconnect():
    print("Client disconnected")


def _authenticate_socket_token(token):
    """Validates a socket token the way token auth validates HTTP requests.

    Returns the ``users`` row on success, ``None`` if the session is revoked
    or the account is not active. Raises ``SignatureExpired`` for an expired
    token (so the caller can tell the client to renew) and ``BadSignature``
    for a forged one.
    """
    metadata = jws.loads(token)
    username = metadata.get("user")
    user = database.get_user(username) if username else None
    if not _is_active_user(user):
        return None
    session = database.get_session(metadata.get("token"))
    if session is None or session["active"] not in (True, 1):
        return None
    if session["user_id"] != user["id"] and user["state"] != "ADMIN":
        return None
    return user


@socketio.on("join_rooms")
def handle_join(token):
    try:
        user = _authenticate_socket_token(token)
        if user is None:
            return
        channels = database.get_channels(user["username"])
        for channel in channels:
            # Room names are normalised to strings so a join always matches the
            # room a `msg` is emitted to (see `handle_message`).
            join_room(str(channel["id"]))
    except SignatureExpired:
        emit("error", "Signature expired")
    except Exception as e:
        print(e)


@socketio.on("msg")
def handle_message(message):
    try:
        msg_parsed = json.loads(message)

        user = _authenticate_socket_token(msg_parsed["sender"])
        if user is None:
            emit("error", "Not authorized")
            return 0

        username = user["username"]
        channel = msg_parsed["channel"]
        room = str(channel)

        # Only members of a channel may post to it or see it live.
        if not database.is_channel_member(channel, username):
            emit("error", "Not authorized")
            return 0

        previous_message = None
        if "previous_message" in msg_parsed:
            previous_message = msg_parsed["previous_message"]

        if msg_parsed["message_type"] == "TEXT_MESSAGE_UPDATE":
            previous_message_row = database.get_message(msg_parsed["previous_message"])
            if (
                previous_message_row is None
                or previous_message_row["sender"] != user["id"]
            ):
                print("Attempt to edit other users message!")
                raise Exception("invalid edit attempt")

        elif msg_parsed["message_type"] == "USER_TYPING":
            # when we reveive a user_typing msg, we don't save it.
            msg = {}
            msg["sender"] = username
            msg["message_type"] = msg_parsed["message_type"]
            msg["sent_time"] = msg_parsed["sent_time"]
            msg["channel"] = channel

            emit("msg", msg, room=room)
            return 0

        # Shares must quote a real message. Rebuild the quoted `source`
        # server-side from its id so a client cannot forge who said what.
        message_body = msg_parsed["message"]
        if msg_parsed["message_type"] == "SHARE_MESSAGE":
            source = message_body.get("source") if isinstance(message_body, dict) else None
            source_id = source.get("id") if isinstance(source, dict) else None
            quoted = (
                database.get_message_with_sender(source_id)
                if source_id is not None
                else None
            )
            if quoted is None or not database.is_channel_member(
                quoted["channel"], username
            ):
                emit("error", "Unknown quoted message")
                return 0
            safe_source = {
                "id": quoted["id"],
                "sender": quoted["username"],
                "message_type": quoted["message_type"],
                "message": json.loads(quoted["message"])
                if quoted["message"] is not None
                else None,
                "sent_time": int(quoted["sent_time"])
                if quoted["sent_time"] is not None
                else None,
                "previous_message": quoted["previous_message"],
                "channel": quoted["channel"],
            }
            message_body = {
                "source": safe_source,
                "message": message_body.get("message"),
            }

        row = database.insert_message(
            username,
            channel,
            json.dumps(message_body),
            msg_parsed["message_type"],
            int(datetime.now().timestamp()),
            previous_message,
        )

        if row is not None:
            msg = {}
            msg["id"] = row["id"]
            msg["sender"] = username
            msg["message_type"] = row["message_type"]
            msg["message"] = json.loads(row["message"])
            msg["sent_time"] = int(row["sent_time"])
            msg["previous_message"] = row["previous_message"]
            msg["nonce"] = msg_parsed["nonce"]
            msg["channel"] = channel
            emit("msg", msg, room=room)
        else:
            emit("error", "Wrong message")
    except SignatureExpired as e:
        emit("error", "Signature expired")
        print(e)
    except Exception as e:
        emit("error", "bad message")
        print(e)


@basic_auth.verify_password
def verify_password(username, password):
    g.user = None
    user = database.get_user_credentials(username)
    if (
        user
        and _is_active_user(user)
        and check_password_hash(user["password"], password)
    ):
        g.user = username
        return True
    return False


@token_auth.verify_token
def verify_token(token):
    g.user = None
    try:
        data = jws.loads(token)
    except:  # noqa: E722
        return False
    if "user" in data:
        # ("token validation request")
        user = database.get_user(data["user"])
        if user and (user["state"] == "USER" or user["state"] == "ADMIN"):
            session = database.get_session(data["token"])
            # print(session)
            # print(user)
            if (
                session != None
                and session["active"] == True
                and (session["user_id"] == user["id"] or user["state"] == "ADMIN")
            ):
                g.user = data["user"]
                # print("token valid")
                return True

    print("token not valid")
    return False


@app.route("/messages")
@multi_auth.login_required
def messages():

    channel = request.args.get("channel")
    initial_msg_id = int(request.args.get("initial_msg_id"))

    # Only members of a channel may read its history.
    if not database.is_channel_member(channel, g.user):
        return "Not a member of this channel", 403

    result = []
    for i, row in enumerate(database.get_messages(channel, initial_msg_id)):
        msg = {}
        msg["id"] = row["id"]
        msg["sender"] = row["username"]
        msg["message_type"] = row["message_type"]
        msg["message"] = json.loads(row["message"])
        msg["sent_time"] = row["sent_time"]
        msg["previous_message"] = row["previous_message"]
        msg["channel"] = channel
        # print(row)
        result.append(msg)

    # print(result)
    return json.dumps(result)


@app.route("/messages/count")
@multi_auth.login_required
def count_messages():
    return json.dumps(database.get_daily_message_count())


@app.route("/")
@multi_auth.login_required
def index():
    return "Hello, %s!" % g.user


@app.route("/channels")
@multi_auth.login_required
def get_channels():

    channels = database.get_channels(g.user)

    for channel in channels:
        channel["users"] = database.get_users_for_channel(channel["id"])

    return json.dumps(channels)


@app.route("/channels", methods=["POST"])
@multi_auth.login_required
def create_channel():

    name = request.form["name"]
    public = "PUBLIC" if request.form["public"] == "true" else "PRIVATE"

    channel = database.insert_channel(name, public)
    database.insert_channel_member(channel["id"], g.user)

    return json.dumps(channel)


@app.route("/channels/add_user", methods=["POST"])
@multi_auth.login_required
def add_user_to_channel():

    channel_id = request.form["channel_id"]
    username = request.form["username"]

    # Only existing members of a channel may add other users to it.
    if not database.is_channel_member(channel_id, g.user):
        return "Not a member of this channel", 403

    database.insert_channel_member(channel_id, username)

    return "ok", 200


@app.route("/channels/search", methods=["POST"])
@multi_auth.login_required
def search_in_channel():

    channel = request.form["channel_id"]
    query = request.form["query"]

    # Only members of a channel may search it.
    if not database.is_channel_member(channel, g.user):
        return "Not a member of this channel", 403

    results = database.search(query, channel)

    return json.dumps(results)


@app.route("/channels/count")
@multi_auth.login_required
def count_channels():
    return json.dumps(database.get_channel_count())


@app.route("/files", methods=["POST"])
@multi_auth.login_required
def upload_files():
    if request.method == "POST":
        # print(request.files)
        files = []
        for filename in request.files:
            f = request.files[filename]
            identifier = secrets.token_urlsafe(64)
            path = os.path.join("data", identifier + "_" + secure_filename(f.filename))
            f.save(path)
            size = os.path.getsize(path)

            data = {
                "file": identifier,
                "user": g.user,
                "type": magic.from_file(path, mime=True),
                "size": size,
                "full_name": secure_filename(f.filename),
            }

            database.insert_file(
                identifier,
                g.user,
                magic.from_file(path, mime=True),
                size,
                secure_filename(f.filename),
            )

            files.append(data)

        return json.dumps(files), 200


@app.route("/files", methods=["GET"])
def get_file():
    file_identifier = request.args.get("f")
    show = request.args.get("show")

    result = database.get_file(file_identifier)

    if not result:
        return "File could not be uniquely identified.", 404

    file_path = "data/" + result["file"] + "_" + result["full_name"]

    # Only known-safe types may render inline; anything that could carry script
    # (HTML, SVG, ...) is always sent as an attachment, and `nosniff` stops the
    # browser from second-guessing the declared type. This prevents a file
    # uploaded to the app's own origin from executing as a page.
    inline = bool(show) and result["type"] in INLINE_MIME_TYPES
    disposition = "inline" if inline else "attachment"

    # Streamed from disk, and conditional=True answers Range requests with 206:
    # Safari only plays video when it can fetch byte ranges, and it lets every
    # browser seek without downloading the whole file. send_file resolves
    # relative paths against the package directory, hence abspath.
    response = send_file(
        os.path.abspath(file_path),
        mimetype=result["type"],
        conditional=True,
        cache_timeout=3600,
    )
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Content-disposition"] = "{}; filename={}".format(
        disposition, result["full_name"]
    )
    return response


@app.route("/files/count")
@multi_auth.login_required
def count_files():
    return json.dumps(database.get_file_count())


@app.route("/emojis/list", methods=["POST"])
@multi_auth.login_required
def upload_slack_emojis():

    if not os.path.exists("emojis/"):
        os.makedirs("emojis/")

    for filename in request.files:
        f = request.files[filename]
        emoji = json.load(f)["emoji"]
        for e in emoji:
            if not emoji[e].startswith("alias:"):
                safe_name = _safe_emoji_name(e)
                if safe_name is None:
                    continue
                try:
                    _download_remote_image(
                        emoji[e], os.path.join("emojis", safe_name)
                    )
                except (ValueError, OSError, urllib.error.URLError):
                    # Skip emoji whose URL is not allowed or cannot be fetched.
                    continue
                database.insert_emoji(
                    g.user, safe_name, safe_name, datetime.now().timestamp()
                )
    return "ok", 200


@app.route("/emoji", methods=["POST"])
@multi_auth.login_required
def upload_emoji():
    "Add one emoji from a post request to the database and store it in `/emojis`."

    e = request.form["name"]
    safe_name = _safe_emoji_name(e)
    if safe_name is None:
        return "Invalid emoji name", 400

    if not os.path.exists("emojis/"):
        os.makedirs("emojis/")

    f = request.files["file"]

    path = os.path.join("emojis", safe_name)
    f.save(path)

    database.insert_emoji(g.user, safe_name, safe_name, datetime.now().timestamp())

    return "ok", 200


@app.route("/emojis/list", methods=["GET"])
@multi_auth.login_required
def get_emoji_list():

    emojis = []
    for row in database.get_emojis():
        emojis.append(
            {
                "name": row["name"],
                "short_names": [row["name"]],
                "emoticons": [],
                "keywords": ["custom"],
                "imageUrl": "emoji/{}".format(row["file"]),
            }
        )

    return json.dumps(emojis)


@app.route("/emoji/<file_identifier>", methods=["GET"])
def get_emoji(file_identifier):
    if file_identifier == "alias":
        emoji = request.args.get("e")[1:-1]
        resolved = database.get_emoji(emoji)
        if not resolved:
            return "Error", 404
        file_identifier = resolved["file"]

    safe_name = _safe_emoji_name(file_identifier)
    if safe_name is None:
        return "Error", 404

    file_path = "emojis/{}".format(safe_name)
    try:
        with open(file_path, mode="rb") as fp:
            f = fp.read()
            return Response(
                f,
                mimetype="image/png",
                headers={
                    "Cache-Control": "public, max-age=3600",
                    "Content-disposition": "attachment; filename={}".format(
                        safe_name
                    ),
                },
            )
    except FileNotFoundError as e:
        return "Error", 500


@app.route("/emoji/<file_identifier>", methods=["DELETE"])
@multi_auth.login_required
def delete_emoji(file_identifier):
    if not current_user_is_admin():
        return "Admin privileges required", 403

    if file_identifier == "alias":
        emoji = request.args.get("e")[1:-1]
        resolved = database.get_emoji(emoji)
        if not resolved:
            return "ok", 200
        file_identifier = resolved["file"]

    safe_name = _safe_emoji_name(file_identifier)
    if safe_name is None:
        return "Invalid emoji name", 400

    file_path = "emojis/{}".format(safe_name)

    print("deleting emoji")
    try:

        os.remove(file_path)
    except OSError:
        print("Emoji file not found during removal.")

    database.delete_emoji(safe_name)
    return "ok", 200


@app.route("/emojis", methods=["DELETE"])
@multi_auth.login_required
def delete_emojis():
    if not current_user_is_admin():
        return "Admin privileges required", 403

    print("deleting all emoji")

    try:
        if os.path.isdir("emojis"):
            for name in os.listdir("emojis"):
                emoji_path = os.path.join("emojis", name)
                if os.path.isfile(emoji_path):
                    os.remove(emoji_path)
    except OSError:
        pass

    database.delete_all_emoji()

    return "ok", 200


@app.route("/users")
@multi_auth.login_required
def get_users():
    return json.dumps(database.get_users())


@app.route("/user/<username>")
@multi_auth.login_required
def get_user(username: str):
    return json.dumps(database.get_public_user(username))


@app.route("/user")
@multi_auth.login_required
def get_user_self():
    return json.dumps(database.get_user(g.user))


@app.route("/user", methods=["POST"])
@multi_auth.login_required
def set_user_self():
    if g.user != request.form["username"]:
        return (
            "Hold on buddy, I'm not a hot-boiling waterhead and I do know you're trying to fool me! Your username should match the username we have for you, you can't change that.",
            418,
        )

    database.update_user(request.form)
    return "ok", 200


@app.route("/users/status", methods=["POST"])
@multi_auth.login_required
def set_status():
    """
    Sets the user status to the provided state, which can be:
    - `ADMIN`
    - `USER`
    - `DISABLED`
    - `REQUESTED`

    Admin only.
    """

    if not current_user_is_admin():
        return "Admin privileges required", 403

    required = ["username", "status"]

    for var in required:
        if var not in request.form:
            return "Key required: {}".format(var), 400

    if request.form["status"] not in ("ADMIN", "USER", "DISABLED", "REQUESTED"):
        return "Invalid status", 400

    database.set_user_status(request.form["username"], request.form["status"])

    return "ok", 200


@app.route("/users/sessions")
@multi_auth.login_required
def get_sessions():

    return json.dumps(database.get_sessions(g.user))


@app.route("/users/sessions/<id>", methods=["DELETE"])
@multi_auth.login_required
def delete_session(id: int):
    """Disables the given session id, but only for its owner or an admin."""

    session = database.get_session(id)
    if session is None:
        return "ok", 200

    me = database.get_public_user(g.user)
    if me is None or (
        session["user_id"] != me["id"] and me["state"] != "ADMIN"
    ):
        return "Not authorized", 403

    database.disable_session(id)

    return "ok", 200


@app.route("/users/picture", methods=["POST"])
@multi_auth.login_required
def set_picture():
    """Updates the profile picture of the logged in user in the database."""

    required = ["file_identifier"]

    for var in required:
        if var not in request.form:
            return "Key required: {}".format(var), 400

    print("update picture")

    database.set_user_picture(g.user, request.form["file_identifier"])

    return "ok", 200


@app.route("/status", methods=["GET"])
def server_status():
    return json.dumps({"backend": 0, "database": database.status()})


@app.route("/signup", methods=["POST"])
def signup():

    required = ["email", "password", "name"]

    for var in required:
        if var not in request.form:
            return "Key required: {}".format(var), 400

    print("Signup request received")
    result = database.insert_user(
        request.form["email"],
        generate_password_hash(request.form["password"]),
        request.form["name"],
        "REQUESTED",
    )

    if not result:
        return "Failed to create user", 400

    # All users are in channel 1 ("General") by default
    database.insert_channel_member(1, request.form["email"])

    return {
        "token": jws.dumps({"user": request.form["email"], "token": 1}).decode("ascii"),
        "queue": "non-valid-queue",
        "channel_id": 1,
    }


@app.route("/login", methods=["get"])
@basic_auth.login_required
def login():
    """
    Login endpoint for a client with two responsabilities:
        - Create a JWT for the client to use on other endpoints.
        - Register the created device/token.

    Returns the JWT.
    """

    # Create the queue
    # connection = pika.BlockingConnection(pika.ConnectionParameters(host="localhost"))
    # channel = connection.channel()

    # result = channel.queue_declare(queue=secrets.token_urlsafe(16), durable=True)
    # queue_name = result.method.queue
    # channel.queue_bind(exchange="amq.direct", queue=queue_name, routing_key="1")
    # print(" [x] Sent %r:%r" % ("1", message))
    # connection.close()

    session = database.insert_session(
        g.user,
        int(time.time()),
        request.user_agent.platform,
        request.user_agent.browser,
        int(time.time()) + app.config["EXPIRES"],
    )

    # Create token and return it
    return {
        "token": jws.dumps({"user": g.user, "token": session["id"]}).decode("ascii"),
        "queue": "non-valid-queue",
        "channel_id": 1,
    }


def run():
    socketio.run(app, host="0.0.0.0", port=9000, log_output=True)
