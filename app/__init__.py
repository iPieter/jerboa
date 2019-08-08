import os
from flask import Flask, g, request, abort, Response, jsonify
from flask_cors import CORS
import pandas as pd
import json
import sqlite3
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
import datetime


conn = sqlite3.connect("data/data.db", check_same_thread=False)

c = conn.cursor()
from flask_socketio import SocketIO

app = Flask(__name__)
CORS(app)
app.config["SECRET_KEY"] = "top secret!"
socketio = SocketIO(app)
jws = JWS(app.config["SECRET_KEY"], expires_in=7 * 24 * 3600)

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
    print("received message: " + message)
    print(request.sid)
    # emit("msg", message, room=request.sid)
    msg_parsed = json.loads(message)
    print(msg_parsed["sender"])

    try:
        metadata = jws.loads(msg_parsed["sender"])
        print("parsed:")
        print(metadata)
        msg_parsed.pop("sender")
        user = sql_to_dict(
            """
            select display_name from users where username = :username limit 1
            """,
            {"username": metadata["user"]},
        )
        if user:
            msg_parsed["sender"] = user[0]["display_name"]
            print(msg_parsed)
            emit("msg", msg_parsed, room="1")
            c.execute(
                """INSERT INTO messages (sender, channel, message, sent_time, message_type)
            VALUES(?, ?, ?, ?, ?)""",
                (
                    msg_parsed["sender"],
                    msg_parsed["channel"],
                    json.dumps(msg_parsed["message"]),
                    msg_parsed["sent_time"],
                    msg_parsed["message_type"],
                ),
            )
            conn.commit()
        else:
            emit("error", "Invalid signature")
    except SignatureExpired as e:
        emit("error", "Signature expired")
        print(e)
    except Exception as e:
        print(e)


@basic_auth.verify_password
def verify_password(username, password):
    g.user = None
    user = sql_to_dict(
        """
    select display_name, password from users where username = :username limit 1
    """,
        {"username": username},
    )
    if user:
        if check_password_hash(user[0]["password"], password):
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
        user = sql_to_dict(
            """
            select display_name from users where username = :username limit 1
            """,
            {"username": data["user"]},
        )
        print("token requested")
        print(user)
        if user:
            g.user = data["user"]
            return True
    return False


@app.route("/messages")
@multi_auth.login_required
def messages():
    channel = request.args.get("channel")
    initial_msg_id = request.args.get("initial_msg_id")

    print(initial_msg_id)

    if int(initial_msg_id) == 0:
        query = """select * from messages 
        where channel==:channel 
        order by id desc
        limit 30 
        """
    else:
        query = """select * from messages 
        where channel==:channel 
        and id < :initial_msg_id
        order by id desc
        limit 10 
        """

    result = []
    for row in c.execute(query, {"channel": channel, "initial_msg_id": initial_msg_id}):

        obj = {}
        names = list(map(lambda x: x[0], c.description))
        for pair in zip(names, row):
            if pair[0] == "message":
                try:
                    # this is needed to un-escape the json data
                    # in the future, this could be done a bit better perhaps?
                    obj[pair[0]] = json.loads(pair[1])
                except:
                    obj[pair[0]] = pair[1]
            else:
                obj[pair[0]] = pair[1]
        result.append(obj)

    return json.dumps(result)


@app.route("/")
@multi_auth.login_required
def index():
    return "Hello, %s!" % g.user


@app.route("/channels/count")
@multi_auth.login_required
def count_channels():

    result = sql_to_dict(
        """
    select channel, count(*) from messages group by channel
    """
    )

    return json.dumps(result)


@app.route("/files", methods=["POST"])
@multi_auth.login_required
def upload_files():
    if request.method == "POST":
        print(request.files)
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

            c.execute(
                """INSERT INTO files (file, user_id, type, size, full_name)
        VALUES(:file, :user, :type, :size, :full_name)""",
                data,
            )
            conn.commit()
            files.append(data)

        return json.dumps(files), 200


@app.route("/files", methods=["GET"])
def get_file():
    file_identifier = request.args.get("f")

    print(file_identifier)

    results = sql_to_dict(
        """select * from files where file == :f""", {"f": file_identifier}
    )

    if len(results) != 1:
        return "File could not be uniquely identified.", 404

    file_path = "data/" + results[0]["file"] + "_" + results[0]["full_name"]
    print(file_path)
    with open(file_path, mode="rb") as fp:
        f = fp.read()
        return Response(
            f,
            mimetype="text/csv",
            headers={
                "Content-disposition": "attachment; filename={}".format(
                    results[0]["full_name"]
                )
            },
        )
    return "Error", 500


@app.route("/files/count")
@multi_auth.login_required
def count_files():

    result = sql_to_dict(
        """
    select type, count(*), sum(size) from files group by type
    """
    )

    return json.dumps(result)


@app.route("/emojis/list", methods=["POST"])
@multi_auth.login_required
def upload_slack_emojis():

    print(request.files)
    for filename in request.files:
        f = request.files[filename]
        emoji = json.load(f)["emoji"]
        for e in emoji:
            print(e)
            if not emoji[e].startswith("alias:"):
                urllib.request.urlretrieve(emoji[e], "emojis/{}".format(e))
                data = {
                    "name": e,
                    "file": e,
                    "user": g.user,
                    "added": datetime.datetime.now(),
                }

                c.execute(
                    """INSERT INTO emojis (name, file, user, added)
            VALUES(:name, :file, :user, :added)""",
                    data,
                )

        conn.commit()

    return "ok", 200


@app.route("/emojis/list", methods=["GET"])
@multi_auth.login_required
def get_emoji_list():

    emojis = []
    for row in c.execute("SELECT * FROM emojis"):

        obj = {}
        names = list(map(lambda x: x[0], c.description))
        for pair in zip(names, row):
            obj[pair[0]] = pair[1]

        emojis.append(
            {
                "name": obj["name"],
                "text": "",
                "short_names": [obj["name"]],
                "emoticons": [],
                "keywords": ["custom"],
                "imageUrl": "http://localhost:9000/emoji/{}".format(obj["file"]),
            }
        )

    print(emojis)
    return json.dumps(emojis)


@app.route("/emoji/<file_identifier>", methods=["GET"])
def get_emoji(file_identifier):
    if file_identifier == "alias":
        emoji = request.args.get("e")[1:-1]
        print("stripped emoji: {}".format(emoji))
        file_identifier = next(
            c.execute(
                """select file from emojis where name == :emoji""", {"emoji": emoji}
            )
        )[0]

    print(file_identifier)

    file_path = "emojis/{}".format(file_identifier)
    print(file_path)
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


@app.route("/users")
@multi_auth.login_required
def get_users():
    result = sql_to_dict(
        """
        select display_name, username, profile_image from users
        """
    )

    return json.dumps(result)


@app.route("/signup", methods=["POST"])
def signup():

    required = ["email", "password", "name"]

    for var in required:
        if var not in request.form:
            return "Key required: {}".format(var), 400

    print("Request: {}".format(request.form["email"]))
    c.execute(
        """INSERT INTO users (username, password, display_name, state)
        VALUES(?, ?, ?, ?)""",
        (
            request.form["email"],
            generate_password_hash(request.form["password"]),
            request.form["name"],
            "REQUESTED",
        ),
    )
    conn.commit()

    return {
        "token": jws.dumps({"user": request.form["email"], "token": 1}).decode("ascii"),
        "queue": "non-valid-queue",
    }


@app.route("/login", methods=["get"])
@basic_auth.login_required
def login():
    """
    Login endpoint for a client with three responsabilities:
        - Create a JWT for the client to use on other endpoints.
        - Register the created device/token.
        - Construct a personal queue for the device.

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

    # Create token and return it
    return {
        "token": jws.dumps({"user": g.user, "token": 1}).decode("ascii"),
        "queue": "non-valid-queue",
    }


def sql_to_dict(query, values={}):
    result = []
    for row in c.execute(query, values):

        obj = {}
        names = list(map(lambda x: x[0], c.description))
        for pair in zip(names, row):
            obj[pair[0]] = pair[1]
        result.append(obj)

    return result


def run():
    socketio.run(app, port=9000)
