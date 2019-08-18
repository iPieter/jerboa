import requests
import pytest
import logging
from base64 import b64encode
import socketio
import json
import random
import string

logging.basicConfig(level=logging.DEBUG, filename="tests.log")

@pytest.fixture(params=[
    "",
    "messages",
    "login"])
def url(request):
    logging.info("INSIDE FIXTURE")
    logging.info(request.param)
    return request.param

class TestBackend:

    def test_url_requires_login(self, url):
        """
        Test that a given :url requires a password/token to access
        """
        logging.info("Testing {}".format(url))
        r = requests.get("http://localhost:9000/{}".format(url))

        assert r.status_code != 200

    def test_url_with_login(self, url):
        """
        Test that a url succesfully resolves with credentials
        """
        logging.info("Testing {}".format(url))
        r = requests.get("http://localhost:9000/{}".format(url), auth=("abc", "hello"))

        assert r.status_code == 200

    def test_ws(self):
        """
        Test connection with ws and that messages are actually saved
        """

        r = requests.get("http://localhost:9000/login", auth=("abc", "hello"))
        assert r.status_code == 200

        token = r.json()["token"]

        sio = socketio.Client(reconnection=False)

        success = False
        test_msg = ''.join(random.choices(string.ascii_uppercase + string.digits, k=100))

        @sio.event
        def msg(msg):
            logging.debug("received msg")
            sio.disconnect()

            nonlocal success
            if test_msg in msg["message"]:
                success = True

        @sio.event
        def error(err):
            logging.debug("Error with ws connection")
            sio.disconnect()

        @sio.event
        def connect():
            logging.debug('connection established')
            sio.emit('msg', json.dumps({
                    'sender': token,
                    "message_type" : "TEXT_MESSAGE",
                    "channel" : "1",
                    "message" : test_msg,
                    "sent_time" : "FIXME",
                    "signature" : "test"
                }))

        @sio.event
        def disconnect():
            logging.debug('disconnected from server')

        sio.connect('http://localhost:9000')
        sio.wait()

        assert success, "Failed to send websocket message!"

        r = requests.get("http://localhost:9000/messages", auth=("abc", "hello"))
        assert r.status_code == 200

        for msg in r.json():
            if test_msg in msg["message"]:
                return

        assert False, "Message not found in db!"
