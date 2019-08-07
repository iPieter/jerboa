<template>
  <div class="container container-login text-center">
    <form class="form-signup">
      <img
        class="mb-4"
        src="https://emoji.slack-edge.com/T7738P6P3/mr-vijgen-na-pasen/707493cf1eb3974e.png"
        alt
        width="72"
        height="72"
      />
      <h1 class="h3 mb-3 font-weight-normal">Create an account</h1>
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
      <label for="inputEmail" class="sr-only">Display name</label>
      <input
        type="text"
        id="inputDisplayName"
        class="form-control"
        placeholder="Display name"
        v-model="name"
        required
        autofocus
      />
      <label for="inputPassword" class="sr-only">Password</label>
      <b-form-input
        type="password"
        id="inputPassword"
        class="form-control"
        placeholder="Password"
        v-model="password"
        :state="password.length >  6 "
        required
      />
      <label for="inputPassword" class="sr-only">Retype password</label>
      <b-form-input
        type="password"
        id="inputPassword2"
        class="form-control"
        placeholder="Retype password"
        v-model="password2"
        required
        :state="password2 != '' && password == password2"
      />
      <button
        class="btn btn-lg btn-primary btn-block"
        type="button"
        v-on:click="signup"
        v-if="signing_up"
      >Sign up</button>
      <button class="btn btn-lg btn-primary btn-block" type="button" disabled v-else>
        <span class="spinner-border spinner-border-sm" role="status" aria-hidden="true"></span>
        <span class="sr-only">Loading...</span>
      </button>
      <p class="mt-5 mb-3 text-muted">random plaats voor random tekst</p>
    </form>
  </div>
</template>


<script>
import Vue from "vue";
import axios from "axios";

export default {
  name: "signup",
  data() {
    return {
      signing_up: true,
      email: "",
      name: "",
      password: "",
      password2: ""
    };
  },
  components: {},
  created() {},
  props: {},
  methods: {
    signup() {
      this.logging_in = false;
      var _this = this;
      console.log({
        email: _this.email,
        name: _this.name,
        password: _this.password
      });

      var bodyFormData = new FormData();
      bodyFormData.set("email", _this.email);
      bodyFormData.set("name", _this.name);
      bodyFormData.set("password", _this.password);

      axios.defaults.baseURL = process.env.VUE_APP_SERVER_BASE;

      axios({
        method: "post",
        headers: { "Content-Type": "multipart/form-data" },
        url: "signup",
        data: bodyFormData
      })
        .then(function(response) {
          // handle success
          console.log(response);
          _this.$router.push({ name: "chat", params: response.data });
        })
        .catch(function(error) {
          // handle error
          console.log(error);
          _this.signing_up = true;
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

.form-signup {
  width: 100%;
  max-width: 330px;
  padding: 15px;
  margin: 0 auto;
}
.form-signup .checkbox {
  font-weight: 400;
}
.form-signup .form-control {
  position: relative;
  box-sizing: border-box;
  height: auto;
  padding: 10px;
  font-size: 16px;
}
.form-signup .form-control:focus {
  z-index: 2;
}
.form-signup input {
  margin-bottom: -1px;
  border-top-right-radius: 0;
  border-top-left-radius: 0;
  border-bottom-right-radius: 0;
  border-bottom-left-radius: 0;
}

#inputEmail {
  margin-top: 10px;
  border-top-left-radius: 3px;
  border-top-right-radius: 3px;
}
#inputPassword2 {
  margin-bottom: 10px;
  border-bottom-left-radius: 3px;
  border-bottom-right-radius: 3px;
}
</style>
