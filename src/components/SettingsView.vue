<template>
  <div class="container">
    <div class="py-5 text-center">
      <img class="d-block mx-auto mb-4" src="icon.png" alt width="72" height="72" />
      <h1>Profile and settings</h1>
      <cite class="lead">
        Historically, privacy was almost implicit, because it was hard to find and gather information. But in the digital world, whether it's digital cameras or satellites or just what you click on, we need to have more explicit rules - not just for governments but for private companies.
        <br />— Bill Gates
      </cite>
    </div>

    <div class="row">
      <div class="col-md-4 order-md-2 mb-4">
        <h4 class="d-flex justify-content-between align-items-center mb-3">
          <span class="text-muted">Logged in sessions</span>
          <span class="badge badge-secondary badge-pill">3</span>
        </h4>
        <ul class="list-group mb-3">
          <li class="list-group-item d-flex justify-content-between lh-condensed">
            <div>
              <h6 class="my-0">Safari</h6>
              <small class="text-muted">Last seen 2h ago</small>
            </div>
            <a href class>Log out</a>
          </li>
          <li class="list-group-item d-flex justify-content-between bg-light">
            <div class="text-success">
              <h6 class="my-0">Firefox</h6>
              <small>This device</small>
            </div>
          </li>
          <li class="list-group-item d-flex justify-content-between lh-condensed">
            <div>
              <h6 class="my-0">Safari for iOS</h6>
              <small class="text-muted">currently online</small>
            </div>
            <a href class>Log out</a>
          </li>
        </ul>
      </div>
      <div class="col-md-8 order-md-1">
        <h4 class="mb-3">Profile information</h4>
        <form class="needs-validation" novalidate>
          <div class="row">
            <div class="col-md-2 mb-3">
              <label for="firstName">Title</label>
              <input type="text" class="form-control" id="firstName" placeholder value />
            </div>
            <div class="col-md-5 mb-3">
              <label for="firstName">First name</label>
              <input type="text" class="form-control" id="firstName" placeholder value required />
              <div class="invalid-feedback">Valid first name is required.</div>
            </div>
            <div class="col-md-5 mb-3">
              <label for="lastName">Last name</label>
              <input type="text" class="form-control" id="lastName" placeholder value required />
              <div class="invalid-feedback">Valid last name is required.</div>
            </div>
          </div>

          <div class="mb-3">
            <label for="username">Username</label>
            <div class="input-group">
              <div class="input-group-prepend">
                <span class="input-group-text">@</span>
              </div>
              <input type="text" class="form-control" id="username" placeholder="Username" required />
              <div class="invalid-feedback" style="width: 100%;">Your username is required.</div>
            </div>
          </div>

          <div class="mb-3">
            <label for="email">
              Email
              <span class="text-muted">(Optional)</span>
            </label>
            <input type="email" class="form-control" id="email" placeholder="you@example.com" />
            <div
              class="invalid-feedback"
            >Please enter a valid email address if you want email notifications.</div>
          </div>

          <div class="row">
            <div class="col-md-5 mb-3">
              <label for="country">Language</label>
              <select class="custom-select d-block w-100" id="language" required>
                <option value>English</option>
              </select>
              <div class="invalid-feedback">Please select a valid language.</div>
            </div>
            <div class="col-md-7 mb-3">
              <label for="state">Time zone</label>
              <select class="custom-select d-block w-100" id="timezone" required>
                <option value>Set the time zone automagically</option>
                <option>(UTC+01:00) Brussels, Copenhagen, Madrid, Paris</option>
              </select>
              <div class="invalid-feedback">Please provide a time zone.</div>
            </div>
          </div>
          <div class="custom-control custom-checkbox">
            <input type="checkbox" class="custom-control-input" id="email-notifications" />
            <label
              class="custom-control-label"
              for="email-notifications"
            >Forward unread messages to my email address</label>
          </div>
          <div class="custom-control custom-checkbox">
            <input type="checkbox" class="custom-control-input" id="show-online" />
            <label
              class="custom-control-label"
              for="show-online"
            >Show an online indicator based on my active devices</label>
          </div>
          <button
            class="mt-4 btn btn-outline-primary btn-lg btn-block"
            type="submit"
          >Update my profile</button>
        </form>
        <form>
          <hr class="mb-4" />

          <h4 class="mb-3">Password</h4>

          <div class="row">
            <div class="col-md-6 mb-3">
              <label for="password">Password</label>
              <input type="password" class="form-control" id="password" placeholder required />
              <div class="invalid-feedback">A password is kind of required when changing a password</div>
            </div>
            <div class="col-md-6 mb-3">
              <label for="password-confirm">Retype password</label>
              <input
                type="password"
                class="form-control"
                id="password-confirm"
                placeholder
                required
              />
              <div class="invalid-feedback">Both passwords don't match</div>
            </div>
          </div>

          <button
            class="mt-4 btn btn-outline-primary btn-lg btn-block"
            type="submit"
          >Update password</button>
        </form>
        <div>
          <hr class="mb-4" />

          <h4 class="mb-3">Profile picture</h4>

          <div class="row">
            <div class="col-md-12 mb-3">
              <label for="file">Password</label>
              <b-form-file
                v-model="file"
                :state="Boolean(file)"
                id="file"
                placeholder="Choose a file..."
                drop-placeholder="Drop file here..."
              ></b-form-file>
              <div class="invalid-feedback">Something's wrong with this file...</div>
            </div>
          </div>

          <button
            class="mt-4 btn btn-outline-primary btn-lg btn-block"
            type="submit"
            v-on:click="uploadProfile"
          >Update profile picture</button>
        </div>
      </div>
    </div>

    <div class="mt-3">Selected file: {{ file ? file.name : '' }}</div>
  </div>
</template>


<script>
import Vue from "vue";
import axios from "axios";
import BootstrapVue from "bootstrap-vue";

Vue.use(BootstrapVue);

export default {
  name: "settings",
  data() {
    return {
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
  },
  props: {},
  methods: {
    handleError(error) {
      console.log(error);
      if (error.response.status == "401") {
        _this.$router.push({ name: "login" });
      }
    },
    uploadProfile() {
      let formData = new FormData();

      /*
          Iteate over any file sent over appending the files
          to the form data.
        */

      formData.append("files[0]", this.file);

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
          console.log(response.data);
          var text = _this.message;

          let profile_url = response.data[0].file;

          //_this.socket.emit("msg", JSON.stringify(msg));

          var bodyFormData = new FormData();
          bodyFormData.set("file_identifier", profile_url);

          axios({
            method: "post",
            headers: { "Content-Type": "multipart/form-data" },
            url: "users/picture",
            data: bodyFormData
          })
            .then(function(response) {
              console.log(response);
              _this.loadUsers();
            })
            .catch(_this.handleError);

          //this.messages.push(msg);
          _this.file = "";
        })
        .catch(this.handleError);
    }
  }
};
</script>

<style lang="scss">
</style>
