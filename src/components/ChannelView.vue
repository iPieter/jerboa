<template>
  <div class="container container-chat">
    <div class="container input-group mb-3 type_msg px-0">
      <div v-if="showEmojiHelper" class="col-12 emoji-predictor">
          <div v-for="(emoji, index) in emojiPredictions" 
              class="emoji-prediction "
              v-bind:class="{'emoji-selected': index === currentSelectedEmoji}">
            {{ emoji.name }}
            <img :src="base_url + emoji.imageUrl">
          </div>
      </div>
      <textarea
        class="form-control col-auto"
        id="inlineFormInput"
        placeholder="Message"
        autofocus
        @keydown.tab.exact="handleTab"
        @keydown.tab.shift.exact="handleReverseTab"
        @keydown.right="handleTab"
        @keydown.left="handleReverseTab"
        @keydown.escape.exact="showEmojiHelper = false"
        @keydown.tab.exact.prevent
        @keydown.enter.exact.prevent
        @keyup.enter.exact="handleEnter"
        @keydown.enter.shift.exact="newline"
        @keypress="updateEmojiShower"
        v-model="message"
        v-bind:rows="rows"
        v-on:paste="handlePaste"
      />
      <div class="input-group-append">
        <label hidden>
          Files
          <input type="file" id="files" ref="files" multiple v-on:change="handleFilesUpload()" />
        </label>
        <b-dropdown right text dropup variant="outline">
          <template slot="button-content" v-if="files.length > 0">({{files.length}})</template>
          <b-dropdown-item v-on:click="addImage()" href="#">Upload image</b-dropdown-item>
          <b-dropdown-item v-on:click="addFiles()" href="#">Upload file</b-dropdown-item>
          <b-dropdown-divider v-if="files.length > 0" />
          <b-dropdown-item v-for="(file, key) in files">
            {{ file.name }}
            <span
              class="text-muted ml-1 float-right"
              v-on:click="removeFile( key )"
            >x</span>
          </b-dropdown-item>
        </b-dropdown>
      </div>
      <div class="input-group-append" v-if="custom_emojis.length > 0">
        <b-button variant="outline" v-on:click="emoji = !emoji">🙃</b-button>
        <picker
          class="emoji-picker"
          @select="addEmoji"
          v-bind:style="emoji? '':'display: none'"
          :custom="custom_emojis"
          title="Pick your emoji…"
          emoji="upside_down_face"
        />
      </div>
      <div class="input-group-append">
        <button class="btn btn-primary btn-sm" type="button" v-on:click="send">Send</button>
      </div>
    </div>
    <div id="messages" class="messages">
      <div class="text-muted mx-auto p-2" style="width: 200px;">
        <a href="#" v-on:click="loadMessages()">load more...</a>
      </div>
      <message v-for="message in messages" :msg="message" v-if="rst"></message>
    </div>
  </div>
</template>


<script>
import Vue from "vue";
import Message from "./Message";
import axios from "axios";
import { Picker } from "emoji-mart-vue";
import VueFuse from 'vue-fuse'
Vue.use(VueFuse)

//import paste from "../paste";

export default {
  name: "channel",
  data() {
    return {
      id: "",
      message: "",
      messages: [],
      connected: false,
      socket: {},
      user_id: "",
      error: "",
      rows: 1,
      files: [],
      image: false,
      emoji: false,
      custom_emojis: [],
      initial_msg_id: 0,
      rst: true,
      visible: false,
      showEmojiHelper : false,
      emojiPredictions : [],
      currentSelectedEmoji : 0,
      base_url : process.env.VUE_APP_SERVER_BASE
    };
  },
  components: { Message, Picker },
  created() {
    console.log("base url: " + process.env.VUE_APP_SERVER_BASE);
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
    axios
      .get("messages", {
        params: {
          channel: "1",
          initial_msg_id: _this.initial_msg_id
        }
      })
      .then(function(response) {
        console.log(response);
        _this.messages = response.data.reverse();
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
          error.response && (
          error.response.status == "401" ||
          error.response == "Signature expired" ||
          error.response == "Invalid signature"
        )) {
          _this.$router.push({ name: "login" });
        }
      });
        //this could be somewhere else, but since sqlite doesn't really allow async...
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
    document.addEventListener("visibilitychange", () => {
        if (!document.hidden) {
            document.title = "Jerboa";
        }
    }, false);
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
    on_connect() {
      this.connected = true;
    },
    on_connection_lost() {
      this.connected = false;
    },
    on_message(msg) {
      this.messages.push(msg);
      Vue.nextTick(function() {
        var objDiv = document.getElementById("messages");
        objDiv.scrollTop = objDiv.scrollHeight;
      });
      if (document.hidden) {
        document.title = "Jerboa - new messages";
        if (Notification.permission == "granted") {
            var not = new Notification("A new message is available");
        }
      }
    },
    on_error(msg) {
      console.log(msg);
      this.error = msg;
    },
    newline() {
      this.value = this.value + "\n";
      this.rows++;
    },
    addEmoji(value) {
      this.message = this.message + " " + value.colons;
    },
    send() {
      if (this.message || this.files.length != 0) {
        var msg;
        if (this.image && this.files.length != 0) {
          this.submitImages();
        } else if (this.files.length != 0) {
          this.submitFiles();
        } else {
          msg = {
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
          this.rows = 1;
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
    handleTab(event) {
        if (this.showEmojiHelper) {
            event.preventDefault();
            this.currentSelectedEmoji = (this.currentSelectedEmoji + 1) % 
                this.emojiPredictions.length;
        }
         
    },
    handleReverseTab(event) {
        if (this.showEmojiHelper) {
            event.preventDefault();
            this.currentSelectedEmoji--;
            if (this.currentSelectedEmoji < 0)
                this.currentSelectedEmoji = this.emojiPredictions.length -1;
        }
         
    },
    handleEnter(event) {
        if (this.showEmojiHelper) {
            var name = this.emojiPredictions[this.currentSelectedEmoji].name;
            var textarea = document.getElementById("inlineFormInput");
            var lastColon = this.message.lastIndexOf(":", textarea.selectionStart);
            if (lastColon >= 0) {
                this.message = this.message.substring(0, lastColon) + ":" + name + ":" + " ";
                this.showEmojiHelper = false;
                this.currentSelectedEmoji = 0;
            }

        } else {
            this.send();
        } 
    },
    updateEmojiShower(event) {
        var textarea = document.getElementById("inlineFormInput");

        //if (textarea.selectionStart != textarea.selectionEnd)
        //    return;

        var lastColon = this.message.lastIndexOf(":", textarea.selectionStart);
        if (lastColon >= 0) {
            var lastWord = this.message.substring(lastColon, textarea.selectionStart + 1);
            lastWord += event.key;
            this.showEmojiHelper = !(/\s/g.test(lastWord));
            if (this.showEmojiHelper) {
                var searchOptions = {
                    keys : ["name"],
                    threshold : 0.2
                };
                this.$search(lastWord.substring(1), this.custom_emojis, { keys:["name"]})
                .then(result => {
                    this.emojiPredictions = result.slice(0, Math.min(result.length, 10));
                })
                .catch(err => {
                    console.log(err);    
                });
            }
        }
    }, 

    /*
        Submits files to the server
      */
    submitFiles() {
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
          }
        })
        .then(function(response) {
          console.log("SUCCESS!!");
          console.log(response.data);
          let msg = {
            message_type: "FILES_MESSAGE",
            sender: _this.token,
            channel: "1",
            message: { message: _this.message, files: response.data },
            sent_time: new Date(),
            signature: "na"
          };
          _this.socket.emit("msg", JSON.stringify(msg));

          //this.messages.push(msg);
          _this.message = "";
          _this.rows = 1;
          _this.files = [];
        })
        .catch(function(response) {
          console.log("FAILURE!!");
          console.log(response);
        });
    },
    submitImages() {
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
          }
        })
        .then(function(response) {
          console.log("SUCCESS!!");
          console.log(response.data);
          var text = _this.message;

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
          _this.message = "";
          _this.rows = 1;
          _this.files = [];
          this.image = false;
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
      console.log("paste event");
      console.log(data);
      console.log(data.clipboardData.types);
      console.log(data.clipboardData.files[0]);
      this.files.push(data.clipboardData.files[0]);
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
            _this.messages.unshift(m);
            console.log(m);
          });
          _this.initial_msg_id = _this.messages[0].id;
          _this.rst = false;
          Vue.nextTick(function() {
            _this.rst = true;
            var objDiv = document.getElementById("messages");
            objDiv.scrollTop = objDiv.scrollHeight;
          });
        });
    }
  }
};
</script>

<style lang="scss">
.container-chat {
  height: 100vh;
  padding-bottom: 54px; //Exactly above message bar
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
}
textarea {
  resize: none;
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

.emoji-predictor {
    border-top: 1px solid #ced4da;
    border-left: 1px solid #ced4da;
    border-right: 1px solid #ced4da;
    border-radius: 5px;
    padding: 3px;
    background: #f9f9f9;
    z-index: 99999;
}

.emoji-prediction {
    display: inline-block;
    padding: 3px;
}
.emoji-prediction img {
    width : 32px;
    margin-right: 10px;
}
.emoji-selected {
    border-radius : 50px ;
    background: #007bff;
    color: white;
    font-weight: bold;
}

html,
body {
  height: 100%;
}

@media screen and (prefers-color-scheme: dark) {
  body {
    background-color: rgb(52, 50, 49) !important;
    color: #bdc3c7;
  }

  .form-control {
    background-color: rgb(52, 50, 49);
    border-color: rgb(32, 31, 31);
  }

  .btn-outline {
    border-top: 1px solid rgb(32, 31, 31);
    border-bottom: 1px solid rgb(32, 31, 31);
    background-color: rgb(52, 50, 49);
  }

  .message-container {
    border-top-color: rgb(32, 31, 31);
  }
}
</style>
