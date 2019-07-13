<template>
  <div class="container">
    <h1>Admin dashboard</h1>
    <b-table striped hover :items="channels"></b-table>
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
      channels: {}
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

    axios.defaults.headers.common["Authorization"] = "Bearer " + this.token;
    console.log(axios.defaults.headers.common["Authorization"]);
    axios
      .get("http://localhost:9000/channels/count", {
        params: {
          channel: "1"
        }
      })
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
  },
  props: {},
  methods: {}
};
</script>

<style lang="scss">
</style>
