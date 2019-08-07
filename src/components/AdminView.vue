<template>
  <div class="container">
    <h1>Admin dashboard</h1>
    <h2>Statistics</h2>
    <b-table striped hover :items="channels"></b-table>
    <b-table striped hover :items="files"></b-table>
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
      channels: {},
      files: {},
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
      .catch(function(error) {
        console.log(error);
        if (error.response.status == "401") {
          _this.$router.push({ name: "login" });
        }
      });
    axios
      .get("files/count", {})
      .then(function(response) {
        console.log(response);
        _this.files = response.data;
      })
      .catch(function(error) {
        console.log(error);
        if (error.response.status == "401") {
          _this.$router.push({ name: "login" });
        }
      });
  },
  props: {},
  methods: {
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
