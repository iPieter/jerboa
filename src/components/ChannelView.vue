<template>
  <div class="container container-chat">
    <div id="messages" class="messages">
      <message v-for="message in messages" :msg="message"></message>
    </div>
    <div class="input-group mb-3 type_msg">
      <textarea
        class="form-control col-auto"
        id="inlineFormInput"
        placeholder="Message"
        autofocus
        @keydown.enter.exact.prevent
        @keyup.enter.exact="send"
        @keydown.enter.shift.exact="newline"
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
      <div class="input-group-append">
        <button class="btn btn-primary btn-sm" type="button" v-on:click="send">Send</button>
      </div>
    </div>
    <div
      class="text-muted font-weight-light"
    >connected: {{this.connected}} | queue: {{this.queue}} | {{this.image}}</div>
    <div class="text-danger">{{this.error}}</div>
  </div>
</template>


<script>
import Vue from "vue";
import Message from "./Message";
import axios from "axios";
//import paste from "../paste";

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
      error: "",
      rows: 1,
      files: [],
      image: false
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
        Vue.nextTick(function() {
          var objDiv = document.getElementById("messages");
          objDiv.scrollTop = objDiv.scrollHeight;
        });
        _this.socket = io("http://localhost:9000", { origins: "*" });
        _this.socket.on("connect", _this.on_connect);
        _this.socket.on("disconnect", _this.on_connection_lost);

        _this.socket.on("msg", _this.on_message);
        _this.socket.on("error", _this.on_error);
      })
      .catch(function(error) {
        console.log(error);
        if (error.response.status == "401") {
          _this.$router.push({ name: "login" });
        }
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
    newline() {
      this.value = this.value + "\n";
      this.rows++;
    },
    send() {
      if (this.message) {
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
        .post("http://localhost:9000/files", formData, {
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
        .post("http://localhost:9000/files", formData, {
          headers: {
            "Content-Type": "multipart/form-data"
          }
        })
        .then(function(response) {
          console.log("SUCCESS!!");
          console.log(response.data);
          var text = _this.message;

          for (var i = 0; i < response.data.length; i++) {
            let url = "http://localhost:9000/files?f=" + response.data[i].file;
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
  display: inline-flex;
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
</style>
