<template>
  <div class="container">
    <div class="py-5 text-center">
      <img class="d-block mx-auto mb-4" src="icon.png" alt width="72" height="72" />
      <h1>Administration and global settings</h1>
      <div class="lead">
        <span class="status-online">
          <span class="breathing"></span>
          Frontend v{{version}}
        </span>
        <span class="status-online">
          <span class="breathing" v-if="status.backend==0"></span>
          <span class="breathing-bas" v-else></span>
          Backend
        </span>
        <span class="status-online">
          <span class="breathing" v-if="status['database'][0]==0"></span>
          <span class="breathing-bad" v-else v-b-tooltip.hover :title="status['database'][1]"></span>
          Database server
        </span>
      </div>
    </div>

    <div class="row">
      <div class="col-md-10 mx-auto row">
        <div class="col">
          <StatsTile :value="sum_messages" secondValue title="Messages" color="purple-tile"></StatsTile>
        </div>
        <div class="col">
          <StatsTile :value="formatBytes(sum_files)" secondValue title="Files" color="orange-tile"></StatsTile>
        </div>
        <div class="col">
          <StatsTile value="idk" secondValue title="Emoji" color="blue-tile"></StatsTile>
        </div>
      </div>
    </div>

    <div class="row justify-content-md-center">
      <b-card no-body class="col-md-10 order-md-1">
        <b-tabs pills card>
          <b-tab title="Users" active>
            <table
              aria-busy="false"
              aria-colcount="4"
              class="table b-table table-striped table-hover"
              id="__BVID__8"
            >
              <!---->
              <!---->
              <thead role="rowgroup" class>
                <!---->
                <tr role="row">
                  <th role="columnheader" scope="col" aria-colindex="1" class>Display Name</th>
                  <th role="columnheader" scope="col" aria-colindex="2" class>Username</th>
                  <th role="columnheader" scope="col" aria-colindex="3" class>Profile Image</th>
                  <th role="columnheader" scope="col" aria-colindex="4" class>Current status</th>
                  <th role="columnheader" scope="col" aria-colindex="4" class>Actions</th>
                </tr>
              </thead>
              <!---->
              <tbody role="rowgroup" class>
                <!---->
                <tr role="row" class v-for="user in users">
                  <td role="cell" aria-colindex="1" class>{{user.display_name}}</td>
                  <td role="cell" aria-colindex="2" class>{{user.username}}</td>
                  <td role="cell" aria-colindex="3" class>
                    <img
                      :src="base + 'files?f=' + user.profile_image"
                      class="rounded img-thumbnail"
                      width="40px"
                    />
                  </td>
                  <td role="cell" aria-colindex="4" class>{{user.state}}</td>
                  <td>
                    <b-button-group>
                      <b-button
                        variant="success"
                        v-if="user.state != 'USER' & user.state != 'ADMIN'"
                        v-on:click="changeStatus(user.username, 'USER')"
                      >Activate</b-button>

                      <b-button
                        variant="danger"
                        v-on:click="changeStatus(user.username, 'DISABLED')"
                        v-if="user.state != 'DISABLED'"
                      >Disable</b-button>
                    </b-button-group>
                  </td>
                </tr>
                <!---->
                <!---->
              </tbody>
            </table>
          </b-tab>
          <b-tab title="Emoji">
            <b-form-file
              v-model="file"
              :state="Boolean(file)"
              placeholder="Choose a file..."
              drop-placeholder="Drop file here..."
            ></b-form-file>
            <div class="mt-3">Selected file: {{ file ? file.name : '' }}</div>
            <button type="submit" class="btn btn-primary" v-on:click="uploadEmojiList">Submit</button>
          </b-tab>
          <b-tab title="Channels">
            <b-table striped hover :items="channels"></b-table>
          </b-tab>
          <b-tab title="Files">
            <b-table striped hover :items="files"></b-table>
          </b-tab>
        </b-tabs>
      </b-card>
    </div>
  </div>
</template>


<script>
import Vue from "vue";
import axios from "axios";
import BootstrapVue from "bootstrap-vue";
import StatsTile from "./StatsTile";

Vue.use(BootstrapVue);

export default {
  name: "admin",
  data() {
    return {
      channels: [],
      files: [],
      users: [],
      status: {},
      file: "",
      version: process.env.VUE_APP_VERSION,
      base: process.env.VUE_APP_SERVER_BASE
    };
  },
  components: { StatsTile },
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
    axios
      .get("channels/count", {})
      .then(function(response) {
        console.log(response);
        _this.channels = response.data;
      })
      .catch(this.handleError);
    axios
      .get("files/count", {})
      .then(function(response) {
        console.log(response);
        _this.files = response.data;
      })
      .catch(this.handleError);
    axios
      .get("status", {})
      .then(function(response) {
        console.log(response);
        _this.status = response.data;
      })
      .catch(this.handleError);
    this.loadUsers();
  },
  props: {},
  methods: {
    loadUsers() {
      let _this = this;

      axios
        .get("users", {})
        .then(function(response) {
          console.log(response);
          _this.users = response.data;
        })
        .catch(this.handleError);
    },
    handleError(error) {
      console.log(error);
      if (error.response.status == "401") {
        _this.$router.push({ name: "login" });
      }
    },
    changeStatus(username, status) {
      var bodyFormData = new FormData();
      bodyFormData.set("username", username);
      bodyFormData.set("status", status);

      var _this = this;

      axios({
        method: "post",
        headers: { "Content-Type": "multipart/form-data" },
        url: "users/status",
        data: bodyFormData
      })
        .then(function(response) {
          console.log(response);
          _this.loadUsers();
        })
        .catch(this.handleError);
    },
    uploadEmojiList() {
      let formData = new FormData();

      /*
          Iteate over any file sent over appending the files
          to the form data.
        */

      formData.append("file", this.file);

      /*
          Make the request to the POST /select-files URL
        */

      let _this = this;
      axios
        .post("emojis/list", formData, {
          headers: {
            "Content-Type": "multipart/form-data"
          }
        })
        .then(function(response) {
          console.log("SUCCESS!!");
          console.log(response.data);

          //this.messages.push(msg);
        })
        .catch(function(response) {
          console.log("FAILURE!!");
          console.log(response);
        });
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
    sum_messages() {
      return this.channels.reduce((a, c) => c.count + a, 0);
    },
    sum_files() {
      return this.files.reduce((a, c) => c.sum + a, 0);
    }
  }
};
</script>

<style lang="scss">
.status-online {
  margin-left: 1em;

  @keyframes breath {
    0% {
      background-color: #30c02b;
    }
    50% {
      background-color: #30c02b22;
    }
    100% {
      background-color: #30c02b;
    }
  }
  .breathing {
    display: inline-block;
    background-color: #30c02b;
    height: 7px;
    width: 7px;
    margin-right: 5px;
    margin-bottom: 3px;
    border-radius: 300px;
    animation: breath 2s infinite;
  }
  @keyframes breath-bad {
    0% {
      background-color: #c02b2b;
    }
    50% {
      background-color: #c02b2b22;
    }
    100% {
      background-color: #c02b2b;
    }
  }
  .breathing-bad {
    display: inline-block;
    background-color: #c02b2b;
    height: 7px;
    width: 7px;
    margin-right: 5px;
    margin-bottom: 3px;
    border-radius: 300px;
    animation: breath-bad 0.5s infinite;
  }
}
.card {
  padding: 0;
}

.card-body {
  padding: 0;

  .table {
    margin-bottom: 0;
  }
}
</style>
