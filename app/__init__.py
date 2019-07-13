import os
from flask import Flask, g, request, abort, Response, jsonify
from flask_cors import CORS
import pandas as pd
import json
import sqlite3
from flask_httpauth import HTTPBasicAuth, HTTPTokenAuth, MultiAuth
from werkzeug.security import generate_password_hash, check_password_hash, safe_str_cmp
import pika
from itsdangerous import TimedJSONWebSignatureSerializer as JWS
from itsdangerous import SignatureExpired
import secrets
from flask_socketio import SocketIO
from flask_socketio import send, emit, join_room

conn = sqlite3.connect("data.db", check_same_thread=False)

c = conn.cursor()
from flask_socketio import SocketIO

app = Flask(__name__)
CORS(app)
app.config["SECRET_KEY"] = "top secret!"
socketio = SocketIO(app)
jws = JWS(app.config["SECRET_KEY"], expires_in=3600)

basic_auth = HTTPBasicAuth()
token_auth = HTTPTokenAuth("Bearer")
multi_auth = MultiAuth(basic_auth, token_auth)


users = {
    "abc": {"name": "Bob", "password": generate_password_hash("hello")},
    "cdf": {"name": "Josh", "password": generate_password_hash("bye")},
}

for user in users.keys():
    token = jws.dumps({"user": user, "token": 1})
    print("*** token for {}: {}\n".format(user, token))


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
        msg_parsed["sender"] = users[metadata["user"]]["name"]
        print(msg_parsed)
        emit("msg", msg_parsed, room="1")
        c.execute(
            """INSERT INTO messages (sender, channel, message, sent_time)
        VALUES(?, ?, ?, ?)""",
            (
                msg_parsed["sender"],
                msg_parsed["channel"],
                msg_parsed["message"],
                msg_parsed["sent_time"],
            ),
        )
        conn.commit()
    except SignatureExpired as e:
        emit("error", "Signature expired")
        print(e)
    except Exception as e:
        print(e)


@basic_auth.verify_password
def verify_password(username, password):
    g.user = None
    if username in users:
        if check_password_hash(users.get(username)["password"], password):
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
        g.user = users[data["user"]]["name"]
        return True
    return False


@app.route("/messages")
@multi_auth.login_required
def messages():
    channel = request.args.get("channel")

    result = []
    for row in c.execute("""select * from messages"""):

        obj = {}
        names = list(map(lambda x: x[0], c.description))
        for pair in zip(names, row):
            obj[pair[0]] = pair[1]
        result.append(obj)

    return json.dumps(result)


@app.route("/")
@multi_auth.login_required
def index():
    return "Hello, %s!" % g.user


@app.route("/users")
@multi_auth.login_required
def get_users():
    return users.keys()


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


@app.route("/test")
def test():
    return "Hello"


def run():
    socketio.run(app, port=9000)
