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
    _this,
    token,
    handleMessages,
    handleConnection,
    handleAuthError,
    baseURL
  ) {
    this.token = token;
    this.handleMessages = handleMessages;
    this.handleConnection = handleConnection;
    this.handleAuthError = handleAuthError;
    this._this = _this;
    this.setupConnection(this._this);

    // Messages are stored in an array, indices to messages are stored
    // in two maps: one for id, one for the date
    this.messages = [];
    this.messageById = new Map();
    this.messageByDate = new Map();

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
    if (
      msg.message_type == "TEXT_MESSAGE" ||
      msg.message_type == "FILES_MESSAGE"
    ) {
      this.messages.push({
        messages: [msg],
        id: msg.id,
        previousMessageDate: new Date(),
        incremental: false,
        sender: msg.sender
      });
    } else if (msg.message_type === "TEXT_MESSAGE_UPDATE") {
      for (var i in this.messages) {
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
    }
    this.messages = this.messages.sort((a, b) => b.id - a.id);
    this.handleMessages(this.messages);
  };

  sendMessage = async msg => {
    this._this.$root.$data.socket.emit("msg", JSON.stringify(msg));
  };

  setupConnection = async () => {
    console.log("Making connection");
    this._this.$root.$data.socket = io(process.env.VUE_APP_SERVER_BASE_WS, {
      origins: "*"
    });

    this._this.$root.$data.socket.on("connect", () => {
      console.log("Connected, loading messages");
      this.loadMessages();
      this.connected = true;
    });
    this._this.$root.$data.socket.on("connect_error", error => {
      console.log("Error connecting");
      console.log(error);
    });
    this._this.$root.$data.socket.on("disconnect", msg => {
      this.handleConnection(false);
    });
    this._this.$root.$data.socket.on("msg", msg => {
      this.handleMessage(msg);
    });
    this._this.$root.$data.socket.on("error", e => {
      console.log("ERROR");
      console.log(e);
    });
  };

  loadMessages = async () => {
    const params = {
      channel: "1",
      initial_msg_id: 0
    };
    try {
      let response = await axios.get("messages", {
        params: {
          channel: params.channel,
          initial_msg_id: params.initial_msg_id
        }
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
