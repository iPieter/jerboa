<template>
  <div id="drop" class="container-fluid row">
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

    <div class="container container-chat" :class="file_preview == '' ? '': 'col-md-4'">
      <div v-if="typing.length != 0" class="typing">
        <transition name="fade">
          <span v-for="(_, key) in typing" :key="key">
            <i class="far fa-comment-dots mr-1"></i>
            <b>{{ users[key].first_name }}</b> is typing
          </span>
        </transition>
      </div>
      <div class="container input-group type_msg px-0 pr-5">
        <message-input
          :send="send"
          :paste="handlePaste"
          :keyup="handleKeyUp"
          :emojis="custom_emojis"
          :typingCallback="typingCallback"
          ref="msgInput"
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
          <b-dropdown right text dropup variant="outline">
            <template slot="button-content" v-if="files.length > 0">
              <i class="fas fa-file-upload"></i>
              {{ files.length }}
            </template>
            <b-dropdown-item v-on:click="addFiles()" href="#">Upload file</b-dropdown-item>
            <b-dropdown-divider v-if="files.length > 0" />
            <b-dropdown-item v-for="(file, key) in files">
              {{ file.name }}
              <span
                class="text-muted ml-1 float-right"
                v-on:click="removeFile(key)"
              >x</span>
            </b-dropdown-item>
          </b-dropdown>
        </div>
        <div class="input-group-append" v-if="custom_emojis.length > 0">
          <b-button variant="outline" v-on:click="emoji = !emoji">🙃</b-button>
          <picker
            class="emoji-picker"
            @select="addEmoji"
            v-bind:style="emoji ? '' : 'display: none'"
            :custom="custom_emojis"
            title="Pick your emoji…"
            emoji="upside_down_face"
          />
        </div>
        <div class="input-group-append">
          <button class="btn btn-primary btn-sm" type="button" v-on:click="handleSend">Send</button>
        </div>
      </div>
      <div id="messages" class="messages">
        <div class="text-muted mx-auto p-2" style="width: 200px;">
          <a href="#" v-on:click="loadMessages()">load more...</a>
        </div>

        <message
          v-for="message in getMessages()"
          :messagesProp="message.messages"
          v-if="rst"
          :key="message.id"
          :ref="`msg_${message.id}`"
          :emojis="custom_emojis"
          :token="token"
          :id="message.id"
          :incremental="message.incremental"
          :sender="users[message.sender]"
        ></message>

        <div
          class="text-muted message-container"
          v-for="(message, index) in $root.$data.unacked_messages[channel_id]"
        >
          <img
            class="avatar"
            :src="base + 'files?f=' + current_user.profile_image"
            v-if="!incremental"
          />
          <div class="message">
            <span class="font-weight-bold">
              {{ current_user.first_name }}
              <b-spinner small label="Small Spinner" type="grow"></b-spinner>
            </span>
            <div class="content" v-if="message.message_type =='TEXT_MESSAGE'">
              <vue-markdown :emoji="true" class="content-msg" :source="message.message"></vue-markdown>
            </div>
            <div class="content" v-else>
              {{message.message.message}}
              <b-card class="m-2 files-card upload-card">
                <b-card-title class="m-3">
                  <b-spinner variant="secondary" small class="mr-1 mb-1" label="Small Spinner"></b-spinner>Uploading your files
                </b-card-title>
                <b-progress
                  :value="message.uploadPercentage"
                  max="100"
                  class="mb-0"
                  :label="`${((value / max) * 100).toFixed(2)}%`"
                ></b-progress>
              </b-card>
            </div>
          </div>
        </div>
        <div class="text-muted mx-auto p-2" style="width: 300px;" v-if="false">
          <span>Uploading your files, now at 0%.</span>
        </div>
      </div>
    </div>
    <iframe class="file_preview col-md-8" v-if="file_preview != ''" :src="file_preview"></iframe>
  </div>
</template>

<script>
import Vue from "vue";
import Message from "./Message";
import VueMarkdown from "vue-markdown";
import MessageInput from "./MessageInput";
import axios from "axios";
import { Picker } from "emoji-mart-vue";
import MessageHandler from "../messageHandler";
var MessageClass = Vue.extend(Message);
Vue.use(VueMarkdown);

export default {
  name: "chat",
  data() {
    return {
      id: "",
      base: "/",
      current_user: {},
      error: "",
      files: [],
      emoji: false,
      custom_emojis: [],
      initial_msg_id: 0,
      rst: true,
      users: {},
      dragging: false,
      file_preview: "",
      typing: {},
      showChannels: false,
      messagehandler: {}
    };
  },
  components: { Message, Picker, MessageInput, VueMarkdown },
  beforeMount() {
    this.base = process.env.VUE_APP_SERVER_BASE;
  },
  created() {
    if ((this.token != null) & (this.token != undefined)) {
      localStorage.token = this.token;
    } else {
      this.token = localStorage.token;
    }
    let _this = this;

    axios.defaults.baseURL = process.env.VUE_APP_SERVER_BASE;
    axios.defaults.headers.common["Authorization"] = "Bearer " + this.token;

    this.$root.$data.visible_channel_id = this.channel_id;
    this.$root.$data.visible_admin = false;
    this.$root.$data.visible_settings = false;

    this.loadUsers();

    this.messagehandler = new MessageHandler(
      this,
      this.token,
      m => {
        Vue.set(_this.$root.$data.messages, _this.channel_id, m);

        _this.scrollDown();
      },
      m => {
        console.log("current connection: " + m);
      },
      m => {
        //_this.$router.push({ name: "login" });
        console.log(m);
      },
      process.env.VUE_APP_SERVER_BASE
    );
    //_this.$router.push({ name: "login" });

    axios
      .get("emojis/list")
      .then(function(response) {
        _this.custom_emojis = response.data;
      })
      .catch(function(error) {
        console.log(error);
      });

    axios
      .get("user")
      .then(function(response) {
        _this.current_user = response.data;
      })
      .catch(function(error) {
        console.log(error);
      });
  },
  watch: {
    channel_id: function() {
      this.$root.$data.visible_channel_id = this.channel_id;
      this.$root.$data.visible_admin = false;
      this.$root.$data.visible_settings = false;
    }
  },
  mounted() {
    if (Notification.permission !== "granted") {
      Notification.requestPermission();
    }
    document.addEventListener(
      "visibilitychange",
      () => {
        if (!document.hidden) {
          document.title = "Jerboa";
        }
      },
      false
    );

    // In the component with the drop zone div:
    document.getElementById("drop").addEventListener("drop", event => {
      event.preventDefault();
      this.dragging = false;

      for (var i = 0; i < event.dataTransfer.files.length; i++) {
        this.files.push(event.dataTransfer.files[i]);
      }
    });

    // In the entry component:
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
  props: {
    token: {
      type: String
    },
    queue: {
      type: String
    },
    channel_id: {
      default: "1"
    }
  },
  methods: {
    loadUsers() {
      let _this = this;

      axios
        .get("users", {})
        .then(function(response) {
          for (var u in response.data) {
            _this.users[response.data[u].username] = response.data[u];
          }
        })
        .catch(this.handleError);
    },
    getMessages() {
      return this.$root.$data.messages[this.channel_id];
    },
    on_connect() {
      this.connected = true;
    },
    on_connection_lost() {
      this.connected = false;
    },
    on_message(msg) {},
    on_message_old(msg) {
      if (msg["message_type"] == "TEXT_MESSAGE_UPDATE") {
        var prevMsg = this.messages.filter(
          m => m.id === msg["previous_message"]
        );
        if (prevMsg.length == 0) {
          console.log("Warning, previous message not found");
          return;
        }
        prevMsg[0].messages.push(msg);
      } else if (msg["message_type"] == "USER_TYPING") {
        //This creates a timeout that will delete the key in `typing` after t seconds
        if (msg.sender != this.current_user.username) {
          let _this = this;

          //first remove old timer
          clearTimeout(this.typing[msg.sender]);

          let t = setTimeout(function() {
            console.log("deleting key for");
            Vue.delete(_this.typing, msg.sender);
          }, 5000);

          Vue.set(this.typing, msg.sender, t);
        }
      } else {
        //first remove typing indication anyway
        let _this = this;

        Vue.delete(_this.typing, msg.sender);

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
        var newMessage = {
          messages: [msg],
          id: msg.id,
          previousMessageDate: new Date(),
          incremental: incremental,
          sender: msg.sender
        };
        this.messages.push(newMessage);
        delete this.$root.$data.unacked_messages[this.channel_id][msg["nonce"]];
        this.scrollDown();

        this.messages = this.messages = this.messages.sort(
          (a, b) => a.id - b.id
        );
        if (document.hidden) {
          document.title = "Jerboa - new messages";
          if (Notification.permission == "granted") {
            // TODO: insert channel name
            var not = new Notification(msg.sender + "", {
              body: msg.message
            });
          }
        }
      }
    },
    on_error(msg) {
      console.log("error on ws:../error");
      console.log(msg);
      this.error = msg;
    },
    addEmoji(value) {
      var newMessage = this.$refs.msgInput.getMessage() + " " + value.colons;
      this.$refs.msgInput.setMessage(newMessage);
    },
    handleSend() {
      this.send(this.$refs.msgInput.getMessage());
    },
    onChange(e) {
      console.log(e);
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
            sender: this.token,
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
          this.scrollDown();

          this.$refs.msgInput.resetMessage();
          this.emoji = false;
        }
      }
    },
    typingCallback() {
      var msg = {
        message_type: "USER_TYPING",
        sender: this.token,
        channel: this.channel_id,
        sent_time: new Date()
      };

      this.messagehandler.sendMessage(msg);
    },
    /*
        Adds a file
      */
    addFiles() {
      this.$refs.files.click();
    },
    scrollDown() {
      let _this = this;
      Vue.nextTick(function() {
        _this.rst = true;
        var objDiv = document.getElementById("messages");
        objDiv.scrollTop = objDiv.scrollHeight;
      });
    },
    /*
        Submits files to the server
    */
    submitFiles(message, nonce) {
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
        sender: this.token,
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
      this.scrollDown();
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
    },

    /*
        Removes a select file the user has uploaded
      */
    removeFile(key) {
      this.files.splice(key, 1);
    },
    handlePaste(data) {
      if (data.clipboardData.files.length > 0) {
        this.files.push(data.clipboardData.files[0]);
      }
    },
    handleKeyUp(event) {
      if (this.$refs.msgInput.getMessage().length == 0) {
        var lastID = this.$root.$data.messages[this.channel_id][
          this.$root.$data.messages[this.channel_id].length - 1
        ].id;
        var el = this.$refs["msg_" + lastID][0];
        if (el) el.toggleEdit();
        event.preventDefault();
      }
    }
  }
};
</script>

<style lang="scss">
body,
html {
  overflow-x: hidden;
  overflow-y: auto;
}

#drop {
  //height: 100vh;

  .container-chat {
    height: calc(100vh - 120px);
  }
}

.upload-card .progress {
  height: 1em;
  border-top-left-radius: 0;
  border-top-right-radius: 0;
}

.drop-area {
  height: 100vh;
  width: 100vw;
  z-index: 10000;
  padding: 5px;
  background-color: #f2f7f8aa;
  position: absolute;

  div {
    border: 5px dashed #56aee9;
    height: 100%;
    width: 100%;
    padding-top: 10%;
    h1,
    h2 {
      color: #eef4f8;
    }
  }
}

.messages {
  height: 100%;
  max-height: calc(100vh-120px);
  margin-bottom: 60px; //Exactly above message bar

  padding: 0;
  overflow: auto;
  -webkit-overflow-scrolling: touch;
}

.type_msg {
  flex-grow: 0; /* default 0 */
  display: inline-flex;
  position: fixed;
  bottom: 0;
  margin-bottom: 22px;
  z-index: 999;
}

.typing {
  bottom: 0;
  position: absolute;
  font-size: 12px;
  font-weight: 100;
  color: #797d81;
  margin-bottom: 3px;
}

.btn-outline {
  border-top: 1px solid #ced4da;
  border-bottom: 1px solid #ced4da;
  background: #fff;
  color: #ced4da;
}

.emoji-picker {
  position: absolute;
  will-change: transform;
  bottom: 0px;
  right: 0px;
  -webkit-transform: translate3d(0px, -50px, 0px);
  transform: translate3d(px, -374px, 0px);
}

.file_preview {
  height: 100vh;
  padding-left: 0;
  padding-right: 0;
  border: none;
  margin-right: -30px;
}

html,
body {
  height: 100%;
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
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.5s;
}
.fade-enter,
.fade-leave-to {
  opacity: 0;
}
</style>
