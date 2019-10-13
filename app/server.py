import os
import shutil
from flask import Flask, g, request, abort, Response, jsonify
from flask_cors import CORS
import pandas as pd
import simplejson as json
import time
from flask_httpauth import HTTPBasicAuth, HTTPTokenAuth, MultiAuth
from werkzeug import secure_filename
from werkzeug.security import generate_password_hash, check_password_hash, safe_str_cmp
import pika
from itsdangerous import TimedJSONWebSignatureSerializer as JWS
from itsdangerous import SignatureExpired
import secrets
from flask_socketio import SocketIO
from flask_socketio import send, emit, join_room
import magic
import urllib.request
from app.database import Database
from datetime import datetime

assert "db_pass" in os.environ
assert "flask_secret" in os.environ

from flask_socketio import SocketIO

app = Flask(__name__)
CORS(app)
app.config["SECRET_KEY"] = os.environ["flask_secret"]
app.config["EXPIRES"] = 7 * 24 * 3600
socketio = SocketIO(app, cors_allowed_origins="*", engineiologger=True, logger=True)
jws = JWS(app.config["SECRET_KEY"], expires_in=app.config["EXPIRES"])
database = Database(os.environ["db_pass"])

basic_auth = HTTPBasicAuth()
token_auth = HTTPTokenAuth("Bearer")
multi_auth = MultiAuth(basic_auth, token_auth)


@socketio.on("connect")
def test_connect():
    print("connected")
    join_room("1")


@socketio.on("disconnect")
def test_disconnect():
    print("Client disconnected")


@socketio.on("msg")
def handle_message(message):
    try:
        print("received message: " + message)
        print(request.sid)
        # emit("msg", message, room=request.sid)
        msg_parsed = json.loads(message)
        print(msg_parsed["sender"])

        metadata = jws.loads(msg_parsed["sender"])
        print("parsed:")
        print(metadata)

        previous_message = None
        if "previous_message" in msg_parsed:
            previous_message = msg_parsed["previous_message"]

        user = database.get_user(metadata["user"])

        if msg_parsed["message_type"] == "TEXT_MESSAGE_UPDATE":
            previous_message_row = database.get_message(msg_parsed["previous_message"])
            if (
                previous_message_row is None
                or previous_message_row["sender"] != user["id"]
            ):
                print("Attempt to edit other users message!")
                raise Exception("invalid edit attempt")

        row = database.insert_message(
            metadata["user"],
            msg_parsed["channel"],
            json.dumps(msg_parsed["message"]),
            msg_parsed["message_type"],
            int(datetime.now().timestamp()),
            previous_message,
        )

        if row is not None:
            msg = {}
            msg["id"] = row["id"]
            msg["sender"] = user["username"]
            msg["message_type"] = row["message_type"]
            msg["message"] = json.loads(row["message"])
            msg["sent_time"] = int(row["sent_time"])
            msg["previous_message"] = row["previous_message"]
            print(msg)
            emit("msg", msg, room="1")
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
    user = database.get_user(username)
    if user and check_password_hash(user["password"], password):
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
        print("token validation request")
        user = database.get_user(data["user"])
        if user and (user["state"] == "USER" or user["state"] == "ADMIN"):
            session = database.get_session(data["token"])
            print(session)
            print(user)
            if (
                session != None
                and session["active"] == True
                and (session["user_id"] == user["id"] or user["state"] == "ADMIN")
            ):
                g.user = data["user"]
                print("token valid")
                return True

    print("token not valid")
    return False


@app.route("/messages")
@multi_auth.login_required
def messages():

    channel = request.args.get("channel")
    initial_msg_id = int(request.args.get("initial_msg_id"))

    # print(initial_msg_id)

    result = []
    for i, row in enumerate(database.get_messages(channel, initial_msg_id)):
        msg = {}
        msg["id"] = row["id"]
        msg["sender"] = row["username"]
        msg["message_type"] = row["message_type"]
        msg["message"] = json.loads(row["message"])
        msg["sent_time"] = row["sent_time"]
        msg["previous_message"] = row["previous_message"]
        # print(row)
        result.append(msg)

    # print(result)
    return json.dumps(result)


@app.route("/")
@multi_auth.login_required
def index():
    return "Hello, %s!" % g.user


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

    # print(file_identifier)

    result = database.get_file(file_identifier)

    if not result:
        return "File could not be uniquely identified.", 404

    file_path = "data/" + result["file"] + "_" + result["full_name"]
    # print(file_path)
    with open(file_path, mode="rb") as fp:
        f = fp.read()
        return Response(
            f,
            mimetype=result["type"],
            headers={
                "Content-disposition": "attachment; filename={}".format(
                    result["full_name"]
                )
            },
        )
    return "Error", 500


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
                urllib.request.urlretrieve(emoji[e], "emojis/{}".format(e))
                database.insert_emoji(g.user, e, e, datetime.now().timestamp())
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
        file_identifier = database.get_emoji(emoji)

    file_path = "emojis/{}".format(file_identifier)
    try:
        with open(file_path, mode="rb") as fp:
            f = fp.read()
            return Response(
                f,
                mimetype="image/png",
                headers={
                    "Content-disposition": "attachment; filename={}".format(
                        file_identifier
                    )
                },
            )
    except FileNotFoundError as e:
        return "Error", 500

@app.route("/emoji/<file_identifier>", methods=["DELETE"])
def delete_emoji(file_identifier):
    if file_identifier == "alias":
        emoji = request.args.get("e")[1:-1]
        file_identifier = database.get_emoji(emoji)

    file_path = "emojis/{}".format(file_identifier)

    print("deleting emoji {}".format(file_identifier))
    try:
        
        os.remove(file_path)
    except:
        print("Emoji file not found during removal.")
   
    database.delete_emoji(file_identifier)
    return "ok", 200 

@app.route("/emojis", methods=["DELETE"])
def delete_emojis():

    print("deleting all emoji")

    try:    
        shutil.rmtree("/emoji")
    except:
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
    return json.dumps(database.get_user(username))


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
    """

    required = ["username", "status"]

    for var in required:
        if var not in request.form:
            return "Key required: {}".format(var), 400

    database.set_user_status(request.form["username"], request.form["status"])

    return "ok", 200


@app.route("/users/sessions")
@multi_auth.login_required
def get_sessions():

    return json.dumps(database.get_sessions(g.user))


@app.route("/users/sessions/<id>", methods=["DELETE"])
@multi_auth.login_required
def delete_session(id: int):
    """Sets the provided session id on disabled if it is done by the owner of the session or an admin"""

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

    print("update {} to picture {}".format(g.user, request.form["file_identifier"]))

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

    print("Request: {}".format(request.form["email"]))
    result = database.insert_user(
        request.form["email"],
        generate_password_hash(request.form["password"]),
        request.form["name"],
        "REQUESTED",
    )

    if not result:
        return "Failed to create user", 400

    return {
        "token": jws.dumps({"user": request.form["email"], "token": 1}).decode("ascii"),
        "queue": "non-valid-queue",
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

    print("New session with meta-data:")
    print(session)

    # Create token and return it
    return {
        "token": jws.dumps({"user": g.user, "token": session["id"]}).decode("ascii"),
        "queue": "non-valid-queue",
    }


def run():
    socketio.run(app, host="0.0.0.0", port=9000, log_output=True)
