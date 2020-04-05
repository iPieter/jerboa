/*
 *  This class wraps a connection to the server.
 *  It has two responsibilites:
 *  - Easy to lookup a message by id or date
 *  - Handle connection changes and keep the message up to date
 * */
import axios from "axios";

export default class MessageHandler {
  // @param url: ws url
  // @param handleMessages: callback which can be used to listen
  // to message changes
  constructor(
    channel_id,
    token,
    handleMessages,
    handleConnection,
    handleAuthError,
    handleTyping,
    clearTyping,
    clearSentMessages,
    baseURL,
    root_data
  ) {
    this.channel_id = channel_id;
    this.token = token;
    this.handleMessages = handleMessages;
    this.handleConnection = handleConnection;
    this.handleAuthError = handleAuthError;
    this.handleTyping = handleTyping;
    this.clearTyping = clearTyping;
    this.clearSentMessages = clearSentMessages;
    this.root_data = root_data;

    this.setupConnection();

    this.messages = [];

    axios.defaults.baseURL = baseURL;
    axios.defaults.headers.common["Authorization"] = "Bearer " + token;
  }

  handleMessage = async msg => {
    // Add to messages
    // Update two maps
    // Call callback with messages sorted by date

    //TODO: replace by a sane implementation
    for (var i in this.messages) {
      if (msg.id === this.messages[i].id) return;
    }

    // First remove the unacked message, whatever type it may be
    if ("nonce" in msg) this.clearSentMessages(msg.nonce);

    // en only look at messages for current channel, otherwise show notifications
    if (this.channel_id != msg.channel) {
      console.log(msg);
      if (
        msg.message_type == "TEXT_MESSAGE" ||
        msg.message_type == "FILES_MESSAGE"
      ) {
      }
      //this.root_data.notifications.push("new message");
    } else {
      if (
        msg.message_type == "TEXT_MESSAGE" ||
        msg.message_type == "FILES_MESSAGE"
      ) {
        this.clearTyping(msg.sender);

        var incremental = false;
        if (this.messages.length > 0) {
          var previousMessage = this.messages[this.messages.length - 1];
          var lastMessage =
            previousMessage.messages[previousMessage.messages.length - 1];
          if (
            msg["sender"] === lastMessage["sender"] &&
            msg["sent_time"] - lastMessage["sent_time"] < 60
          ) {
            incremental = true;
          }
        }

        this.messages.push({
          messages: [msg],
          id: msg.id,
          previousMessageDate: new Date(),
          incremental: incremental,
          sender: msg.sender
        });
      } else if (msg.message_type === "TEXT_MESSAGE_UPDATE") {
        for (let i in this.messages) {
          if (this.messages[i].id === msg.previous_message) {
            this.messages[i].message = msg.message;
          }
        }
      } else if (msg.message_type === "SHARE_MESSAGE") {
        this.messages.push({
          messages: [msg],
          id: msg.id,
          previousMessageDate: new Date(),
          incremental: false,
          sender: msg.sender
        });
      } else if (msg["message_type"] == "USER_TYPING") {
        this.handleTyping(msg);
      }
      this.messages = this.messages.sort((a, b) => a.id - b.id);
      this.handleMessages(this.messages);
    }
  };

  sendMessage = async msg => {
    this.root_data.socket.emit("msg", JSON.stringify(msg));
  };

  setupConnection = async () => {
    console.log("Making connection");
    this.root_data.socket = io(process.env.VUE_APP_SERVER_BASE_WS, {
      origins: "*"
    });

    this.root_data.socket.on("connect", () => {
      console.log("Connected, loading messages");
      this.loadMessages();
      console.log("Also requesting access to rooms on server.");
      this.root_data.socket.emit("join_rooms", this.token);

      this.connected = true;
    });
    this.root_data.socket.on("connect_error", error => {
      console.log("Error connecting");
      console.log(error);
    });
    this.root_data.socket.on("disconnect", msg => {
      this.handleConnection(false);
    });
    this.root_data.socket.on("msg", msg => {
      this.handleMessage(msg);
    });
    this.root_data.socket.on("error", e => {
      console.log("ERROR");
      console.log(e);
    });
  };

  switchChannels = async new_channel_id => {
    console.log("Switching channels");
    this.channel_id = new_channel_id;
    this.messages = [];
    this.loadMessages();
  };

  loadMessages = async () => {
    const params = {
      channel: this.channel_id,
      initial_msg_id: 0
    };

    try {
      let response = await axios.get("messages", {
        params: params
      });

      console.log(response);

      if (response.status == 401) {
        console.log("Authorization error when fetching messages");
        this.handleAuthError();
        return;
      }

      let responseJson = response.data;
      responseJson = responseJson.reverse();
      for (var i in responseJson) {
        this.handleMessage(responseJson[i]);
      }
      this.handleConnection(true);
    } catch (e) {
      console.log(e);
    }
  };
}
