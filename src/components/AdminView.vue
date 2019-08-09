<template>
  <div class="container">
    <h1>Admin dashboard</h1>
    <h2>Statistics</h2>
    <b-table striped hover :items="channels"></b-table>
    <b-table striped hover :items="files"></b-table>
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
          <td role="cell" aria-colindex="3" class>{{user.profile_image}}</td>
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
    <h2>Emojis</h2>
    <!-- Styled -->
    <b-form-file
      v-model="file"
      :state="Boolean(file)"
      placeholder="Choose a file..."
      drop-placeholder="Drop file here..."
    ></b-form-file>
    <div class="mt-3">Selected file: {{ file ? file.name : '' }}</div>
    <button type="submit" class="btn btn-primary" v-on:click="uploadEmojiList">Submit</button>
  </div>
</template>


<script>
import Vue from "vue";
import axios from "axios";
import BootstrapVue from "bootstrap-vue";

Vue.use(BootstrapVue);

export default {
  name: "admin",
  data() {
    return {
      channels: [],
      files: [],
      users: [],
      file: ""
    };
  },
  components: {},
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
    }
  }
};
</script>

<style lang="scss">
</style>
