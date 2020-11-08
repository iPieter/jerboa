<template>
  <div :class="file_preview == '' ? '' : 'row mx-0'">
    <div id="drop" :class="file_preview == '' ? '' : 'col-md-4'">
      <MenuBar :channel_id="channel_id" />
      <!-- MAIN BODY -->
      <ChannelView
        v-if="connected"
        :messages="messages"
        :unacked_messages="$root.$data.unacked_messages[channel_id]"
        id="messages"
      />
      <div class="info" v-else>
        <div class="text-center pt-5">
          <b-spinner label="Spinning"></b-spinner>
          <p class="mt-2">Sending bits to the server...</p>
        </div>
      </div>
    </div>

    <transition name="fade">
      <div class="drop-area" v-if="dragging">
        <div>
          <h1 class="text-center">
            <i class="fas fa-upload"></i>
          </h1>
          <h2 class="text-center">Drop files to upload</h2>
        </div>
      </div>
    </transition>

    <!-- BOTTOM -->
    <div class="container-fluid composer">
      <div class="col-xl-6 col-md-8 col-sm-12 mx-auto">
        <div class="row transparant">
          <div class="col-2"></div>
          <div class="col-2 mx-auto">
            <b-button variant="link" v-on:click="scroll_down()" v-if="scrolling"
              >scroll down</b-button
            >
          </div>

          <div class="col-2 px-0">
            <div class="typing float-right">
              <transition name="fade">
                <span v-for="(_, key) in typing" :key="key" class="float-right">
                  <img
                    class="d-inline-block small-avatar"
                    :src="
                      base + 'files?f=' + $root.$data.users[key].profile_image
                    "
                  />
                </span>
              </transition>
            </div>
          </div>
        </div>
      </div>
      <div class="row composer-row">
        <div class="col-xl-6 col-md-8 col-sm-12 mx-auto input-group">
          <message-input
            :send="send"
            :paste="handle_paste"
            :keyup="handleKeyUp"
            :emojis="$root.$data.custom_emojis"
            :typingCallback="typing_callback"
            ref="msgInput"
            class=""
          ></message-input>

          <div class="input-group-append">
            <label hidden>
              Files
              <input
                type="file"
                id="files"
                ref="files"
                multiple
                v-on:change="handleFilesUpload()"
              />
            </label>
            <b-dropdown
              right
              text
              dropup
              variant="outline"
              class="btn-composer"
            >
              <template slot="button-content" v-if="files.length > 0">
                <i class="fas fa-file-upload"></i>
                {{ files.length }}
              </template>
              <b-dropdown-item v-on:click="add_files()" href="#"
                >Upload file</b-dropdown-item
              >
              <b-dropdown-divider v-if="files.length > 0" />
              <b-dropdown-item v-for="(file, key) in files" v-bind:key="key">
                {{ file.name }}
                <span
                  class="text-muted ml-1 float-right"
                  v-on:click="delete_file(key)"
                  >x</span
                >
              </b-dropdown-item>
            </b-dropdown>
          </div>

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
    <iframe
      class="file_preview col-md-8"
      v-if="file_preview != ''"
      :src="file_preview"
    ></iframe>
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
      base: "/",
      connected: false,
      custom_emojis: [],
      files: [],
      messages: [],
      scrolling: false,
      dragging: false,
      typing: {},
      file_preview: "",
    };
  },
  props: {
    channel_id: {
      default: "1",
    },
  },
  watch: {
    channel_id: function(new_channel_id) {
      console.log("changing channels to id = " + new_channel_id);
      this.messages = [];
      this.messagehandler.switchChannels(new_channel_id);
    },
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
        (m) => {
          _this.messages = m;

          if (!_this.scrolling) _this.scroll_down();
        },
        (connection) => {
          this.connected = connection;
        },
        () => {
          _this.$router.push({ name: "login" });
        },
        this.on_typing_message,
        this.handle_notifcation,
        this.clear_typing,
        this.clear_sent_messages,
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
          this.submit_files(message, nonce);
        } else {
          msg = {
            message_type: "TEXT_MESSAGE",
            sender: this.$root.$data.token,
            channel: this.channel_id,
            message: message,
            sent_time: new Date(),
            signature: "na",
            nonce: nonce,
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
    on_typing_message(msg) {
      if (msg.sender != this.$root.$data.user.username) {
        let _this = this;

        //first remove old timer
        clearTimeout(this.typing[msg.sender]);

        let t = setTimeout(function() {
          console.log("deleting key for");
          Vue.delete(_this.typing, msg.sender);
        }, 5000);

        Vue.set(this.typing, msg.sender, t);
      }
    },
    clear_typing(sender) {
      Vue.delete(this.typing, sender);
    },
    load_current_user() {
      let _this = this;

      axios
        .get("user")
        .then(function(response) {
          _this.$root.$data.user = response.data;
        })
        .catch(this.handle_api_error);
    },
    handle_paste(data) {
      if (data.clipboardData.files.length > 0) {
        this.files.push(data.clipboardData.files[0]);
      }
    },
    handleKeyUp() {},
    typing_callback() {
      var msg = {
        message_type: "USER_TYPING",
        sender: this.$root.$data.token,
        channel: this.channel_id,
        sent_time: new Date(),
      };

      this.messagehandler.sendMessage(msg);
    },
    handleSend() {
      this.send(this.$refs.msgInput.getMessage());
    },
    handle_scroll() {
      this.scrolling = window.scrollY < window.scrollMaxY - 5;
    },
    handle_notifcation(message) {
      if (document.hidden) {
        document.title = "Jerboa - new messages";
        if (Notification.permission == "granted") {
          var body = message.message;
          if (message.message_type == "FILES_MESSAGE") {
            var title =
              message.sender + " shared " + body.files.length + " file";
            if (body.files.length > 1)
              title =
                message.sender + " shared " + body.files.length + " files";
            new Notification(title, { body: body.message });
          } else {
            new Notification(message.sender + "", {
              body: body,
            });
          }
        }
      }
    },
    submit_files(message, nonce) {
      /*
          Initialize the form data
        */
      let formData = new FormData();

      /*
          Iteate over any file sent over appending the files
          to the form data.
        */
      for (var i = 0; i < this.files.length; i++) {
        let file = this.files[i];

        formData.append("files[" + i + "]", file);
      }
      /*
          Make the request to the POST /select-files URL
      */
      let _this = this;

      let msg = {
        message_type: "FILES_MESSAGE",
        sender: this.$root.$data.token,
        channel: this.channel_id,
        message: {
          message: message,
          files: [],
        },
        sent_time: new Date(),
        signature: "na",
        nonce: nonce,
      };

      if (!(this.channel_id in this.$root.$data.unacked_messages)) {
        console.log("adding key");
        Vue.set(this.$root.$data.unacked_messages, this.channel_id, {});
      }

      Vue.set(this.$root.$data.unacked_messages[this.channel_id], nonce, msg);
      if (!this.scrolling) this.scroll_down();
      _this.files = [];
      this.$refs.msgInput.resetMessage();

      axios
        .post("files", formData, {
          headers: {
            "Content-Type": "multipart/form-data",
          },
          onUploadProgress: function(progressEvent) {
            Vue.set(
              _this.$root.$data.unacked_messages[_this.channel_id][nonce],
              "uploadPercentage",
              parseInt(
                Math.round((progressEvent.loaded * 100) / progressEvent.total)
              )
            );
          }.bind(this),
        })
        .then(function(response) {
          console.log("successfully uploaded file(s).");
          msg.message.files = response.data;
          _this.messagehandler.sendMessage(msg);

          //this.messages.push(msg);
          _this.uploadPercentage = -1;
        })
        .catch(function(response) {
          console.log("FAILURE!!");
          console.log(response);
          _this.uploadPercentage = -1;
        });
    },
    handleFilesUpload() {
      let uploadedFiles = this.$refs.files.files;

      /*
          Adds the uploaded file to the files array
        */
      for (var i = 0; i < uploadedFiles.length; i++) {
        this.files.push(uploadedFiles[i]);
      }
    },
    add_files() {
      this.$refs.files.click();
    },
    delete_file(key) {
      this.files.splice(key, 1);
    },
    load_emojis() {
      let _this = this;
      axios
        .get("emojis/list")
        .then(function(response) {
          _this.$root.$data.custom_emojis = response.data;
        })
        .catch(this.handle_api_error);
    },
    clear_sent_messages(nonce) {
      console.log("trying to clear message");
      try {
        if (nonce in this.$root.$data.unacked_messages[this.channel_id])
          delete this.$root.$data.unacked_messages[this.channel_id][nonce];
      } catch {
        console.log("exception");
      }
    },
    handle_api_error(error) {
      console.log(error);

      if (error.response.status === 401) {
        this.$router.push({ name: "login" });
      }
    },
  },
  created() {
    // When the main component is created, we get everything from local storage
    this.$root.$data.token = localStorage.token;

    // If there is no token, we redirect to login
    if (!this.$root.$data.token) {
      this.$router.push({ name: "login" });
    }
  },
  beforeMount() {
    this.base = process.env.VUE_APP_SERVER_BASE;
  },
  mounted() {
    // When the compontend is created and mounted, we start to connect with our socket server.
    this.create_connection();
    this.load_users();
    this.load_current_user();
    this.load_emojis();

    // add listeners
    window.addEventListener("scroll", this.handle_scroll);

    document.getElementById("drop").addEventListener("drop", (event) => {
      event.preventDefault();
      this.dragging = false;

      for (var i = 0; i < event.dataTransfer.files.length; i++) {
        this.files.push(event.dataTransfer.files[i]);
      }
    });

    window.addEventListener("dragenter", (event) => {
      //this.dragging++;
      this.dragging = true;

      event.stopPropagation();
      event.preventDefault();
    });

    window.addEventListener("dragover", (event) => {
      this.dragging = true;

      event.stopPropagation();
      event.preventDefault();
    });

    window.addEventListener("dragleave", (event) => {
      //this.dragging--;
      //if (this.dragging === 0) {
      this.dragging = false;
      //}

      event.stopPropagation();
      event.preventDefault();
    });

    //finally ask permission for notifications
    if (Notification.permission !== "granted") {
      Notification.requestPermission();
    }
  },
  destroyed() {
    // Finally, remove all event listners
    window.removeEventListener("scroll", this.handle_scroll);
    window.removeEventListener("dragenter");
    window.removeEventListener("dragover");
    window.removeEventListener("dragleave");
    document.getElementById("drop").removeEventListener("drop");
  },
};
</script>

<style lang="scss" scoped>
@import "../style.scss";

.view {
  margin-top: 60px;
  margin-bottom: 55px;
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

.upload-card .progress {
  height: 1em;
  border-top-left-radius: 0;
  border-top-right-radius: 0;
}

.drop-area {
  top: 60px;
  left: 0;
  bottom: 0;
  width: 100vw;
  z-index: 10000;
  padding: 5px;
  background-color: #f2f7f8aa;
  position: fixed;

  div {
    border: 5px dashed #56aee9;
    padding-top: 10%;
    height: 100%;
    h1,
    h2 {
      color: $jerboa_color5;
    }
  }
}

.btn-composer {
  border-top: 1px solid #ced4da;
  border-bottom: 1px solid #ced4da;
  background: #fff;
  color: #ced4da;
  height: calc(1.5em + 0.75rem + 2px);
}

@media screen and (prefers-color-scheme: dark) {
  body {
    background-color: rgb(38, 35, 36) !important;
    color: #bdc3c7;
  }

  .form-control {
    background-color: rgb(38, 35, 36);
    border-color: rgb(52, 51, 51);
  }

  .btn-outline {
    border-top: 1px solid rgb(52, 51, 51);
    border-bottom: 1px solid rgb(52, 51, 51);
    background-color: rgb(38, 35, 36);
  }

  .message-container {
    border-top-color: rgb(42, 41, 41);
  }
  .btn-primary {
    background-color: #284261;
    border-color: #1b5494;
  }
}

@keyframes breathing {
  0% {
    //opacity: 30%;
    transform: scale(120%);
    -webkit-transform: scale(1.2);

    //transform: translate(0, -21px);
  }
  50% {
    //opacity: 100%;
    transform: scale(100%);
    -webkit-transform: scale(1);

    //transform: translate(1px, -20px);
  }
  100% {
    //opacity: 30%;
    //transform: translate(0, -21px);
    transform: scale(120%);
    -webkit-transform: scale(1.2);
  }
}

.typing {
  //position: fixed;
  img {
    border-radius: 100px;
    image-rendering: optimizeQuality;
    height: 18px;
    width: 18px;
    border: solid 1px #f5f5f5;
    background: white;
    animation: breathing 2s linear infinite;
  }
}

.file_preview {
  height: 100vh;
  padding-left: 0;
  padding-right: 0;
  border: none;
  margin-right: -30px;
}
</style>
