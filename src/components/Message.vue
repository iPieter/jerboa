<template>
  <div class="message-container pt-2" @mouseover="hovered = true" @mouseleave="hovered = false">
    <img
      class="avatar"
      src="https://ca.slack-edge.com/T7738P6P3-U76USER16-330ec1edea98-72"
      v-if="!incremental"
    />
    <div class="message">
      <div class="header" v-if="!incremental">
        <span class="font-weight-bold">{{ messages[messages.length - 1].sender }}</span>
        <span class="font-weight-light text-muted ml-2 d-sm-none">{{ smalltime }}</span>
        <span class="font-weight-light text-muted ml-2 d-none d-sm-inline">{{ time }}</span>
      </div>

      <message-input
        v-if="editMode"
        :send="handleSend"
        :paste="handlePaste"
        :escape="() => (editMode = false)"
        :messageProp="messages[messages.length - 1].message"
        :emojis="emojis"
      ></message-input>
      <div v-else class="content mt-0" v-bind:style="incremental ? 'margin-left: 31pt' : ''">
        <div
          v-if="
                        messages[messages.length - 1].message_type == 'TEXT_MESSAGE' ||
                            messages[messages.length - 1].message_type == 'TEXT_MESSAGE_UPDATE'
                    "
        >
          <vue-markdown
            :emoji="true"
            :postrender="postMessageRender"
            class="content-msg"
            :source="messages[messages.length - 1].message"
          ></vue-markdown>
          <span class="font-weight-light text-muted" v-if="edited">
            <i>(edited)</i>
          </span>
          <span>
            <img src="icons/edit24.svg" class="icon" v-if="hovered" @click="editMode = true" />
          </span>
        </div>
        <div v-else>
          <vue-markdown :emoji="false" :postrender="postMessageRender">
            {{
            messages[messages.length - 1].message
            }}
          </vue-markdown>
          <div class="card-deck">
            <div
              class="card mb-4"
              v-for="(file, index) in messages[messages.length - 1].message.files"
              :key="index"
              style="max-width: 20rem;"
            >
              <!--<img src="..." class="card-img-top" alt="..." />-->
              <div class="card-body">
                <h5 class="card-title">{{ file.user }} shared a file</h5>
                <p class="card-text">{{ file.full_name }}</p>
                <a v-bind:href="base + 'files?f=' + file.file" class="btn btn-primary mx-auto">
                  Download
                  <br />
                  ({{ formatBytes(file.size) }})
                </a>
              </div>
              <div class="card-footer">
                <small class="text-muted">{{ file.type }}</small>
              </div>
            </div>
            <div class="file-tile">{{ file }}</div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script>
import Vue from "vue";
import VueMarkdown from "vue-markdown";
import moment from "moment";
import Emoji from "emoji-mart-vue";
import MessageInput from "./MessageInput";

Vue.use(VueMarkdown);
moment.locale("nl-be");

export default {
  name: "message",
  data() {
    return {
      base: "/",
      editMode: false,
      edited: false,
      messages: [],
      hovered: false
    };
  },
  components: {
    VueMarkdown,
    MessageInput
  },
  props: {
    id: {
      type: Number,
      required: true
    },
    incremental: {
      type: Boolean
    },
    messagesProp: {
      type: Array,
      required: true
    },
    emojis: {
      type: Array
    },
    socket: {
      required: true
    },
    token: {
      required: true
    }
  },
  beforeMount() {
    this.base = process.env.VUE_APP_SERVER_BASE;
    this.messages.splice(0, this.messages.length);
    this.messagesProp.forEach(m => this.messages.push(m));
    this.edited = this.messages.length > 1;
  },
  watch: {
    messagesProp: {
      handler() {
        this.edited = true;
        this.messages.splice(0, this.messages.length);
        this.messagesProp.forEach(m => this.messages.push(m));
      },
      deep: true,
      immediate: true
    }
  },
  methods: {
    toggleEdit() {
      this.editMode = true;
    },
    updateMessage(msg) {
      this.edited = true;
      this.messages.push(msg);
    },
    handleSend(content) {
      var msg = {
        message_type: "TEXT_MESSAGE_UPDATE",
        sender: this.token,
        channel: "1",
        message: content,
        sent_time: new Date(),
        signature: "na",
        previous_message: this.id
      };

      this.editMode = false;
      this.socket.emit("msg", JSON.stringify(msg));
    },
    handlePaste() {},
    postMessageRender(htmlData) {
      var re = /:([A-z0-9\-]+(:{2}\S+)?):/g;

      htmlData = htmlData.replace(
        new RegExp(re),
        "<img class='emoji' src='" +
          process.env.VUE_APP_SERVER_BASE +
          "emoji/$1'/ alt=':$1:'>"
      );

      return htmlData;
    },
    formatBytes(bytes) {
      if (bytes == 0) {
        return "0 B";
      }

      var formatArr = ["B", "kB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"];
      var tmptotal;
      var f = 0;

      //round function rounds up, not down. eg. round(30.5,0) will round to 31
      var len = String(Math.round(bytes)).length;

      if (len < 4) {
        tmptotal = bytes;
      } else if (len >= 4 && len < 7) {
        tmptotal = bytes / 1024;
        ++f;
      } else if (len >= 7 && len < 10) {
        tmptotal = bytes / 1024 / 1024;
        f += 2;
      } else if (len >= 10 && len < 13) {
        tmptotal = bytes / 1024 / 1024 / 1024;
        f += 3;
      } else if (len >= 13 && len < 16) {
        tmptotal = bytes / 1024 / 1024 / 1024 / 1024;
        f += 4;
      } else if (len >= 16) {
        tmptotal = bytes / 1024 / 1024 / 1024 / 1024 / 1024;
        f += 5;
      } else {
        tmptotal = bytes;
      }

      tmptotal = tmptotal.toFixed(1);

      //handle if too great of a value and format is passed in
      if (f > 8) {
        return bytes + " B";
      }

      var new_format_out = formatArr[f];
      //round it off it is already in bits
      if (new_format_out == "B") {
        tmptotal = new Number(tmptotal).toFixed(0);
      }

      //strips all trailing zeroes, note the escaped period
      tmptotal = tmptotal.toString().replace(/\.0\$/, "");

      return tmptotal + " " + new_format_out;
    }
  },
  computed: {
    time: function() {
      return moment(
        new Date(this.messages[this.messages.length - 1].sent_time * 1000)
      ).format("LLL");
    },

    smalltime: function() {
      return moment(
        new Date(this.messages[this.messages.length - 1].sent_time * 1000)
      ).format("HH:mm");
    }
  }
};
</script>

<style lang="scss">
.message-container {
  border-top: 1px solid #eff0f1;
  margin-bottom: -4pt;
  line-height: 1;

  .avatar {
    height: 26pt;
    line-height: 26pt;
    width: 26pt;
    position: relative;
    display: inline-block;
    vertical-align: top;
    margin-right: 5pt;
    border-radius: 3pt;
  }

  .message {
    display: inline-block;
    width: 95%;

    .content {
      line-height: 1.5;
    }
    .header {
      display: block;
    }
    .content {
      display: block;
      width: 100%;
    }

    .content-msg {
      display: inline-block;
      width: 90%;
    }

    .content-ctrl {
      display: inline-block;
      width: 10%;
    }

    .content img {
      margin-top: 10px;
      max-width: 75%;
      max-height: 85vh;
      background: #fff;
      padding: 0.5rem;
      box-shadow: 0 0.2rem 1.2rem rgba(0, 0, 0, 0.1);
    }

    .content .icon {
      width: 16px;
      margin-left: 5px;
      margin-top: 0;
      background: transparent;
      padding: 0;
      box-shadow: none;
    }

    .content .emoji {
      display: inline-block;
      width: 1.5em;
      padding: 0;
      background: transparent;
      margin: 0;
      box-shadow: unset;
      margin-top: -0.5ex;
    }

    pre {
      padding-left: 4px;
      margin-left: 5px;
      margin-top: 10px;
      border-left: 4px solid #3498db;
      border-radius: 2px;
    }

    blockquote {
      padding-left: 4px;
      margin-left: 5px;
      margin-top: 10px;
      border-left: 4px solid #bdc3c7;
      border-radius: 2px;
    }
  }
}
</style>
