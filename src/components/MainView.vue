<template>
  <div>
    <MenuBar :channel_id="channel_id" />
    <!-- MAIN BODY -->
    <ChannelView v-if="connected" :messages="messages" id="messages" />
    <div class="info" v-else>
      <div class="text-center pt-5">
        <b-spinner label="Spinning"></b-spinner>
        <p class="mt-2">Sending bits to the server...</p>
      </div>
    </div>

    <!-- BOTTOM -->
    <div class="container-fluid composer">
      <div class="row transparant" v-if="scrolling">
        <div class="col-xl-1 mx-auto">
          <b-button variant="link" v-on:click="scroll_down()"
            >scroll down</b-button
          >
        </div>
      </div>
      <div class="row composer-row">
        <div class="col-xl-6 col-md-8 col-sm-12 mx-auto input-group">
          <message-input
            :send="send"
            :paste="handlePaste"
            :keyup="handleKeyUp"
            :emojis="custom_emojis"
            :typingCallback="typingCallback"
            ref="msgInput"
            class=""
          ></message-input>

          <div class="input-group-append">
            <button
              class="btn btn-primary btn-sm"
              type="button"
              v-on:click="handleSend"
            >
              Send
            </button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script>
import Vue from "vue";
import MenuBar from "./MenuBar";
import ChannelView from "./ChannelView";
import MessageHandler from "../messageHandler";
import MessageInput from "./MessageInput";
import axios from "axios";

export default {
  name: "mainview",
  components: { MenuBar, ChannelView, MessageInput },
  data() {
    return {
      connected: false,
      custom_emojis: [],
      files: [],
      messages: [],
      scrolling: false
    };
  },
  props: {
    channel_id: {
      default: "1"
    }
  },
  watch: {
    channel_id: function(new_channel_id) {
      console.log("changing channels to id = " + new_channel_id);
      this.messages = [];
      this.messagehandler.switchChannels(new_channel_id);
    }
  },
  methods: {
    list_messages() {
      return this.messages;
    },
    scroll_down() {
      Vue.nextTick(function() {
        window.scrollTo(0, document.body.scrollHeight);
      });
    },
    create_connection() {
      let _this = this;

      this.messagehandler = new MessageHandler(
        this.channel_id,
        this.$root.$data.token,
        m => {
          _this.messages = m;

          if (!_this.scrolling) _this.scroll_down();
        },
        connection => {
          this.connected = connection;
        },
        () => {
          _this.$router.push({ name: "login" });
        },
        () => {},
        () => {},
        () => {},
        process.env.VUE_APP_SERVER_BASE,
        this.$root.$data
      );
    },
    send(message) {
      /*
      Sending a message is a bit depending on the type of message, but in general
      they all follow the same outline:
      1. Generate a nonce
      2. Create a message object
         (files should be uploaded at this point, or at least have an identifier)
      3. Send message to server
      4. Move message to unacked messages and display accordingly
      5. Once acked, move to standard, acked message list
      */

      let nonce = Math.random()
        .toString(36)
        .substring(7);

      if (message || this.files.length != 0) {
        var msg;
        if (this.files.length != 0) {
          this.submitFiles(message, nonce);
        } else {
          msg = {
            message_type: "TEXT_MESSAGE",
            sender: this.$root.$data.token,
            channel: this.channel_id,
            message: message,
            sent_time: new Date(),
            signature: "na",
            nonce: nonce
          };

          if (!(this.channel_id in this.$root.$data.unacked_messages)) {
            console.log("adding key");
            Vue.set(this.$root.$data.unacked_messages, this.channel_id, {});
          }

          this.messagehandler.sendMessage(msg);
          Vue.set(
            this.$root.$data.unacked_messages[this.channel_id],
            nonce,
            msg
          );
          //this.scrollDown();

          this.$refs.msgInput.resetMessage();
          //this.emoji = false;
        }
      }
    },
    load_users() {
      let _this = this;

      axios
        .get("users", {})
        .then(function(response) {
          for (var u in response.data) {
            _this.$root.$data.users[response.data[u].username] =
              response.data[u];
          }
        })
        .catch(this.handleError);
    },
    handlePaste() {},
    handleKeyUp() {},
    typingCallback() {},
    handleSend() {
      this.send(this.$refs.msgInput.getMessage());
    },
    handle_scroll() {
      this.scrolling = window.scrollY < window.scrollMaxY - 5;
    }
  },
  created() {
    // When the main component is created, we get everything from local storage
    this.$root.$data.token = localStorage.token;
  },
  mounted() {
    // When the compontend is created and mounted, we start to connect with our socket server.
    this.create_connection();
    this.load_users();

    // add listeners
    window.addEventListener("scroll", this.handle_scroll);
  },
  destroyed() {
    // Finally, remove all event listners
    window.removeEventListener("scroll", this.handle_scroll);
  }
};
</script>

<style lang="scss" scoped>
@import "../style.scss";

.view {
  margin-top: 60px;
  margin-bottom: 50px;
}

.info {
  color: $jerboa_color5;
}

.composer {
  position: fixed;
  bottom: 0;
  margin: auto;
}

.composer-row {
  padding-bottom: 5px;
  background: #f5f5f5;
}

.transparant {
  background: transparent;
}
</style>
