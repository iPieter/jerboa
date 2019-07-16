<template>
  <div class="message-container pt-2">
    <img
      class="avatar"
      src="https://ca.slack-edge.com/T7738P6P3-U76USER16-330ec1edea98-72"
      v-if="!incremental"
    />
    <div class="message">
      <div class="header" v-if="!incremental">
        <span class="font-weight-bold">{{msg.sender}}</span>
        <span class="font-weight-light text-muted ml-2">{{time}}</span>
      </div>

      <div class="content mt-0" v-bind:style="incremental ? 'margin-left: 31pt' : ''">
        <vue-markdown v-if="msg.message_type =='TEXT_MESSAGE'">{{this.msg.message}}</vue-markdown>
        <div v-else>
          <vue-markdown>{{msg.message.message}}</vue-markdown>
          <div class="card-deck">
            <div class="card mb-4" v-for="file in msg.message.files" style="max-width: 20rem;">
              <!--<img src="..." class="card-img-top" alt="..." />-->
              <div class="card-body">
                <h5 class="card-title">{{file.user}} shared a file</h5>
                <p class="card-text">{{file.full_name}}</p>
                <a
                  v-bind:href="'http://localhost:9000/files?f='+file.file"
                  class="btn btn-primary mx-auto"
                >
                  Download
                  <br />
                  ({{formatBytes(file.size)}})
                </a>
              </div>
              <div class="card-footer">
                <small class="text-muted">{{file.type}}</small>
              </div>
            </div>
            <div class="file-tile">{{file}}</div>
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

Vue.use(VueMarkdown);

moment.locale("nl-be");

export default {
  name: "message",
  data() {
    return {};
  },
  components: {
    VueMarkdown
  },
  props: {
    incremental: {
      type: Boolean
    },
    msg: {
      type: Object
    }
  },
  methods: {
    mounted() {},
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
      return moment(this.msg.sent_time).format("LLL");
    }
  }
};
</script>

<style lang="scss">
.message-container {
  border-top: 1px solid #eff0f1;
  display: inline-flex;
  margin-bottom: -4pt;
  line-height: 1;
  .avatar {
    height: 26pt;
    line-height: 26pt;
    width: 26pt;
    position: relative;
    display: inline-block;
    vertical-align: unset;
    margin-right: 5pt;
    border-radius: 3pt;
  }

  .message {
    display: inline-block;

    .content {
      line-height: 1.5;
    }
    .content,
    .header {
      display: block;
    }

    img {
      margin-top: 10px;
      max-width: 90%;
      background: #fff;
      padding: 0.5rem;
      box-shadow: 0 0.2rem 1.2rem rgba(0, 0, 0, 0.1);
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
