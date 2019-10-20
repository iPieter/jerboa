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
      <div class="container input-group mb-3 type_msg px-0 pr-5">
        <message-input
          :send="send"
          :paste="handlePaste"
          :keyup="handleKeyUp"
          :emojis="custom_emojis"
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
            <b-dropdown-item v-on:click="addImage()" href="#">Upload image</b-dropdown-item>
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
          v-for="(message, index) in getMessages()"
          :messagesProp="message.messages"
          v-if="rst"
          :key="index"
          :ref="`msg_${message.id}`"
          :emojis="custom_emojis"
          :socket="socket"
          :token="token"
          :id="message.id"
          :incremental="message.incremental"
          :sender="users[message.sender]"
        ></message>
        <div class="text-muted mx-auto p-2" style="width: 300px;" v-if="uploadPercentage > 0">
          <span>
            <b-spinner variant="secondary" small label="Small Spinner"></b-spinner>
            Uploading your files, now at {{uploadPercentage}}%.
          </span>
        </div>
      </div>
    </div>
    <iframe class="file_preview col-md-8" v-if="file_preview != ''" :src="file_preview"></iframe>
  </div>
</template>

<script>
import Vue from "vue";
import Message from "./Message";
var MessageClass = Vue.extend(Message);
import MessageInput from "./MessageInput";
import axios from "axios";
import { Picker } from "emoji-mart-vue";

//import paste from "../paste";

export default {
  name: "channel",
  data() {
    return {
      id: "",
      messages: [],
      connected: false,
      socket: {},
      user_id: "",
      error: "",
      files: [],
      image: false,
      emoji: false,
      custom_emojis: [],
      initial_msg_id: 0,
      rst: true,
      users: {},
      dragging: false,
      file_preview: "",
      uploadPercentage: -1
    };
  },
  components: { Message, Picker, MessageInput },
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

    axios.defaults.baseURL = process.env.VUE_APP_SERVER_BASE;
    axios.defaults.headers.common["Authorization"] = "Bearer " + this.token;
    console.log(axios.defaults.headers.common["Authorization"]);

    this.loadUsers();

    axios
      .get("messages", {
        params: {
          channel: "1",
          initial_msg_id: _this.initial_msg_id
        }
      })
      .then(function(response) {
        console.log(response);
        response.data.reverse().forEach(m => _this.on_message(m));
        if (response.data.length > 0)
          _this.initial_msg_id = response.data[0].id;

        Vue.nextTick(function() {
          var objDiv = document.getElementById("messages");
          objDiv.scrollTop = objDiv.scrollHeight;
        });
        _this.socket = io(process.env.VUE_APP_SERVER_BASE_WS, { origins: "*" });
        _this.socket.on("connect", _this.on_connect);
        _this.socket.on("disconnect", _this.on_connection_lost);

        _this.socket.on("msg", _this.on_message);
        _this.socket.on("error", _this.on_error);
      })
      .catch(function(error) {
        console.log(error);
        if (
          error.response &&
          (error.response.status == "401" ||
            error.response == "Signature expired" ||
            error.response == "Invalid signature")
        ) {
          _this.$router.push({ name: "login" });
        }
      });
    axios
      .get("emojis/list")
      .then(function(response) {
        _this.custom_emojis = response.data;
        console.log(response.data);
      })
      .catch(function(error) {
        console.log(error);
      });
  },
  mounted() {
    if (Notification.permission !== "denied") {
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
      return this.messages;
    },
    on_connect() {
      this.connected = true;
    },
    on_connection_lost() {
      this.connected = false;
    },
    on_message(msg) {
      if (msg["message_type"] == "TEXT_MESSAGE_UPDATE") {
        var prevMsg = this.messages.filter(
          m => m.id === msg["previous_message"]
        );
        if (prevMsg.length == 0) {
          console.log("Warning, previous message not found");
          return;
        }
        prevMsg[0].messages.push(msg);
      } else {
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
        Vue.nextTick(function() {
          var objDiv = document.getElementById("messages");
          objDiv.scrollTop = objDiv.scrollHeight;
        });
      }
      if (document.hidden) {
        document.title = "Jerboa - new messages";
        if (Notification.permission == "granted") {
          // TODO: insert channel name
          var not = new Notification(msg.sender + "", {
            body: msg.message
          });
        }
      }
    },
    on_error(msg) {
      console.log(msg);
      this.error = msg;
    },
    addEmoji(value) {
      var newMessage = this.$refs.msgInput.getMessage() + " " + value.colons;
      this.$refs.msgInput.setMessage(newMessage);
    },
    handleSend() {
      this.send(this.$refs.msgInput.getMessage());
      this.$refs.msgInput.resetMessage();
    },
    onChange(e) {
      console.log(e);
    },
    send(message) {
      if (message || this.files.length != 0) {
        var msg;
        if (this.image && this.files.length != 0) {
          this.submitImages(message);
        } else if (this.files.length != 0) {
          this.submitFiles(message);
        } else {
          msg = {
            message_type: "TEXT_MESSAGE",
            sender: this.token,
            channel: "1",
            message: message,
            sent_time: new Date(),
            signature: "na"
          };

          this.socket.emit("msg", JSON.stringify(msg));

          //this.messages.push(msg);
          this.emoji = false;
        }
      }
    },
    /*
        Adds a file
      */
    addFiles() {
      this.$refs.files.click();
    },
    addImage() {
      this.$refs.files.click();
      this.image = true;
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
    submitFiles(message) {
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
      axios
        .post("files", formData, {
          headers: {
            "Content-Type": "multipart/form-data"
          },
          onUploadProgress: function(progressEvent) {
            let old = _this.uploadPercentage;
            _this.uploadPercentage = parseInt(
              Math.round((progressEvent.loaded * 100) / progressEvent.total)
            );

            if (old < 0) {
              _this.scrollDown();
            }
          }.bind(this)
        })
        .then(function(response) {
          console.log("SUCCESS!!");
          console.log(response.data);
          let msg = {
            message_type: "FILES_MESSAGE",
            sender: _this.token,
            channel: "1",
            message: {
              message: message,
              files: response.data
            },
            sent_time: new Date(),
            signature: "na"
          };
          _this.socket.emit("msg", JSON.stringify(msg));

          //this.messages.push(msg);
          _this.$refs.msgInput.resetMessage();
          _this.files = [];
          _this.uploadPercentage = -1;
        })
        .catch(function(response) {
          console.log("FAILURE!!");
          console.log(response);
          _this.uploadPercentage = -1;
        });
    },
    submitImages(message) {
      let formData = new FormData();
      for (var i = 0; i < this.files.length; i++) {
        let file = this.files[i];

        formData.append("files[" + i + "]", file);
      }

      var text = message;
      let _this = this;
      axios
        .post("files", formData, {
          headers: {
            "Content-Type": "multipart/form-data"
          }
        })
        .then(function(response) {
          for (var i = 0; i < response.data.length; i++) {
            let url =
              process.env.VUE_APP_SERVER_BASE +
              "files?f=" +
              response.data[i].file;
            text += "\n ![" + url + "](" + url + ")";
          }
          let msg = {
            message_type: "TEXT_MESSAGE",
            sender: _this.token,
            channel: "1",
            message: text,
            sent_time: new Date(),
            signature: "na"
          };
          _this.socket.emit("msg", JSON.stringify(msg));

          //this.messages.push(msg);
          _this.$refs.msgInput.resetMessage();
          _this.rows = 1;
          _this.files = [];
          _this.image = false;
        })
        .catch(function(response) {
          console.log("FAILURE!!");
          console.log(response);
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
      this.image = true;
      if (data.clipboardData.files.length > 0) {
        this.files.push(data.clipboardData.files[0]);
      }
    },
    handleKeyUp(event) {
      if (this.$refs.msgInput.getMessage().length == 0) {
        var lastID = this.messages[this.messages.length - 1].id;
        var el = this.$refs["msg_" + lastID][0];
        if (el) el.toggleEdit();
        event.preventDefault();
      }
    },
    loadMessages() {
      var _this = this;
      axios
        .get("messages", {
          params: {
            channel: "1",
            initial_msg_id: _this.initial_msg_id
          }
        })
        .then(function(response) {
          response.data.forEach(m => {
            _this.on_message(m);
          });
          _this.initial_msg_id = _this.messages[0].id;
          _this.rst = false;
          _this.scrollDown();
        });
    }
  }
};
</script>

<style lang="scss">
.container-chat {
  padding-bottom: 54px; //Exactly above message bar
  max-height: 100vh;
}

#drop {
  height: 100vh;

  .container-chat {
    height: calc(100vh - 0px);
  }
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
      color: #56aee9;
    }
  }
}

.messages {
  height: 100%;
  max-height: 100vh;
  margin: 0;
  padding: 0;
  overflow: auto;
  -webkit-overflow-scrolling: touch;
}

.type_msg {
  flex-grow: 0; /* default 0 */
  display: inline-flex;
  position: absolute;
  bottom: 0;
  z-index: 999;
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
  transition: opacity 0.1s;
}
.fade-enter, .fade-leave-to /* .fade-leave-active below version 2.1.8 */ {
  opacity: 0;
}
</style>
