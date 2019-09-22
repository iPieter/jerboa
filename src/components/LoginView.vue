<template>
  <div class="container container-login text-center">
    <form class="form-signin">
      <img class="mb-4" src="icon.png" alt width="72" height="72" />
      <h1 class="h3 mb-3 font-weight-normal">Please sign in</h1>
      <label for="inputEmail" class="sr-only">Email address</label>
      <input
        type="text"
        id="inputEmail"
        class="form-control"
        placeholder="Email address"
        v-model="email"
        required
        autofocus
      />
      <label for="inputPassword" class="sr-only">Password</label>
      <input
        type="password"
        id="inputPassword"
        class="form-control"
        placeholder="Password"
        v-model="password"
        required
      />
      <div class="checkbox mb-3">
        <label>
          <input type="checkbox" value="remember-me" /> Remember me
        </label>
      </div>
      <button
        class="btn btn-lg btn-primary btn-block"
        type="submit"
        v-on:click="login"
        v-if="logging_in"
      >Sign in</button>
      <button class="btn btn-lg btn-primary btn-block" type="button" disabled v-else>
        <span class="spinner-border spinner-border-sm" role="status" aria-hidden="true"></span>
        <span class="sr-only">Loading...</span>
      </button>
      <p class="mt-5 mb-3 text-muted">
        You can make an account
        <router-link to="signup">here</router-link>!
      </p>
    </form>
  </div>
</template>


<script>
import Vue from "vue";
import axios from "axios";

axios.defaults.baseURL = process.env.VUE_APP_SERVER_BASE;

export default {
  name: "login",
  data() {
    return {
      logging_in: true,
      email: "",
      password: ""
    };
  },
  components: {},
  created() {},
  props: {},
  methods: {
    login() {
      this.logging_in = false;
      var _this = this;
      console.log({
        username: _this.email,
        password: _this.password
      });
      axios({
        method: "get",
        headers: { "X-Requested-With": "application/x-www-form-urlencoded" },
        url: "login",
        auth: {
          username: _this.email,
          password: _this.password
        }
      })
        .then(function(response) {
          // handle success
          console.log(response);
          _this.$router.push({ name: "chat", params: response.data });
        })
        .catch(function(error) {
          // handle error
          console.log(error);
          _this.logging_in = true;
        });
    }
  }
};
</script>

<style lang="scss">
body {
  background-color: #f5f5f5;
}
container-login {
  display: -ms-flexbox;
  display: -webkit-box;
  display: flex;
  -ms-flex-align: center;
  -ms-flex-pack: center;
  -webkit-box-align: center;
  align-items: center;
  -webkit-box-pack: center;
  justify-content: center;
  padding-top: 40px;
  padding-bottom: 40px;
}

.form-signin {
  width: 100%;
  max-width: 330px;
  padding: 15px;
  margin: 0 auto;
}
.form-signin .checkbox {
  font-weight: 400;
}
.form-signin .form-control {
  position: relative;
  box-sizing: border-box;
  height: auto;
  padding: 10px;
  font-size: 16px;
}
.form-signin .form-control:focus {
  z-index: 2;
}
.form-signin input[type="email"] {
  margin-bottom: -1px;
  border-bottom-right-radius: 0;
  border-bottom-left-radius: 0;
}
.form-signin input[type="password"] {
  margin-bottom: 10px;
  border-top-left-radius: 0;
  border-top-right-radius: 0;
}
</style>
