<template>
  <div class="container container-chat">
    <div id="messages" class="messages">
      <message v-for="message in messages" :msg="message"></message>
    </div>
    <div class="input-group mb-3 type_msg">
      <input
        type="text"
        class="form-control col-auto"
        id="inlineFormInput"
        placeholder="Message"
        autofocus
        @keydown.enter="send"
        v-model="message"
      />
      <div class="input-group-append">
        <button class="btn btn-primary btn-sm" type="button" v-on:click="send">Send</button>
      </div>
    </div>
    <div class="text-muted font-weight-light">connected: {{this.connected}} | queue: {{this.queue}}</div>
    <div class="text-danger">{{this.error}}</div>
  </div>
</template>


<script>
import Vue from "vue";
import Message from "./Message";
import axios from "axios";

export default {
  name: "about",
  data() {
    return {
      id: "",
      message: "",
      messages: [],
      connected: false,
      ip: "127.0.0.1:15674",
      socket: {},
      user_id: "",
      error: ""
    };
  },
  components: { Message },
  created() {
    if (this.queue != null) {
      localStorage.queue = this.queue;
    } else {
      this.queue = localStorage.queue;
    }
    if (this.token != null) {
      localStorage.token = this.token;
    } else {
      this.token = localStorage.token;
    }
    let _this = this;

    axios.defaults.headers.common["Authorization"] = "Bearer " + this.token;
    console.log(axios.defaults.headers.common["Authorization"]);
    axios
      .get("http://localhost:9000/messages", {
        params: {
          channel: "1"
        }
      })
      .then(function(response) {
        console.log(response);
        _this.messages = response.data;
        _this.socket = io("http://localhost:9000", { origins: "*" });
        _this.socket.on("connect", _this.on_connect);
        _this.socket.on("disconnect", _this.on_connection_lost);

        _this.socket.on("msg", _this.on_message);
        _this.socket.on("error", _this.on_error);
      });
  },
  mounted() {},
  props: {
    token: {
      type: String
    },
    queue: {
      type: String
    }
  },
  methods: {
    on_connect() {
      this.connected = true;
    },
    on_connection_lost() {
      this.connected = false;
    },
    on_message(msg) {
      console.log(msg);
      this.messages.push(msg);
      Vue.nextTick(function() {
        var objDiv = document.getElementById("messages");
        objDiv.scrollTop = objDiv.scrollHeight;
      });
    },
    on_error(msg) {
      console.log(msg);
      this.error = msg;
    },
    send() {
      if (this.message) {
        var msg = {
          message_type: "TEXT_MESSAGE",
          sender: this.token,
          channel: "1",
          message: this.message,
          sent_time: new Date(),
          signature: "na"
        };
        this.socket.emit("msg", JSON.stringify(msg));

        //this.messages.push(msg);
        this.message = "";
      }
    }
  }
};
</script>

<style lang="scss">
.container-chat {
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  height: 100vh;
}

.message {
  flex-grow: 0;
}

.messages {
  display: grid;
  overflow-y: scroll;
}

.type_msg {
  flex-grow: 0; /* default 0 */
}
</style>
