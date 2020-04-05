<template>
  <div id="drop">
    <MenuBar :channel_id="channel_id" />
    <!-- MAIN BODY -->
    <ChannelView v-if="connected" :messages="messages" id="messages" />
    <div class="info" v-else>
      <div class="text-center pt-5">
        <b-spinner label="Spinning"></b-spinner>
        <p class="mt-2">Sending bits to the server...</p>
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
              <b-dropdown-item v-on:click="addFiles()" href="#"
                >Upload file</b-dropdown-item
              >
              <b-dropdown-divider v-if="files.length > 0" />
              <b-dropdown-item v-for="(file, key) in files">
                {{ file.name }}
                <span
                  class="text-muted ml-1 float-right"
                  v-on:click="removeFile(key)"
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
      scrolling: false,
      dragging: false
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
          this.submit_files(message, nonce);
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
          files: []
        },
        sent_time: new Date(),
        signature: "na",
        nonce: nonce
      };

      if (!(this.channel_id in this.$root.$data.unacked_messages)) {
        console.log("adding key");
        Vue.set(this.$root.$data.unacked_messages, this.channel_id, {});
      }

      Vue.set(this.$root.$data.unacked_messages[this.channel_id], nonce, msg);
      //this.scrollDown();
      _this.files = [];
      this.$refs.msgInput.resetMessage();

      axios
        .post("files", formData, {
          headers: {
            "Content-Type": "multipart/form-data"
          },
          onUploadProgress: function(progressEvent) {
            Vue.set(
              _this.$root.$data.unacked_messages[_this.channel_id][nonce],
              "uploadPercentage",
              parseInt(
                Math.round((progressEvent.loaded * 100) / progressEvent.total)
              )
            );
          }.bind(this)
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
    /*
        Handles the uploading of files
      */
    handleFilesUpload() {
      let uploadedFiles = this.$refs.files.files;

      /*
          Adds the uploaded file to the files array
        */
      for (var i = 0; i < uploadedFiles.length; i++) {
        this.files.push(uploadedFiles[i]);
      }
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

    document.getElementById("drop").addEventListener("drop", event => {
      event.preventDefault();
      this.dragging = false;

      for (var i = 0; i < event.dataTransfer.files.length; i++) {
        this.files.push(event.dataTransfer.files[i]);
      }
    });

    window.addEventListener("dragenter", event => {
      //this.dragging++;
      this.dragging = true;

      event.stopPropagation();
      event.preventDefault();
    });

    window.addEventListener("dragover", event => {
      this.dragging = true;

      event.stopPropagation();
      event.preventDefault();
    });

    window.addEventListener("dragleave", event => {
      //this.dragging--;
      //if (this.dragging === 0) {
      this.dragging = false;
      //}

      event.stopPropagation();
      event.preventDefault();
    });
  },
  destroyed() {
    // Finally, remove all event listners
    window.removeEventListener("scroll", this.handle_scroll);
    window.removeEventListener("dragenter");
    window.removeEventListener("dragover");
    window.removeEventListener("dragleave");
    document.getElementById("drop").removeEventListener("drop");
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
</style>
