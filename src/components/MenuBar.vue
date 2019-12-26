<template>
  <div>
    <nav class="navbar fixed-top navbar-dark">
      <div class="left">
        <a class="navbar-brand" href="#">
          <img class="ml-2 mt-1" src="/icon.png" alt width="30" height="30" />
        </a>
        <b-dropdown id="dropdown-right" left variant="white" class="m-2 navbar-brand">
          <template v-slot:button-content>
            <div
              class="d-inline-block text-left"
              v-if="!$root.$data.visible_admin && !$root.$data.visible_settings"
            >
              <span class="d-block inline-toggle">
                <b>{{getChannel().name}}</b>
              </span>
              <span class="d-block" v-if="getChannel().type == 'PRIVATE'">
                <i class="fas fa-user-secret mr-2"></i>
                Private channel
              </span>
              <span class="d-block" v-else>
                <i class="fas fa-users mr-2"></i>
                Public channel
              </span>
            </div>
            <div class="d-inline-block text-left" v-else-if="$root.$data.visible_admin">
              <span class="d-block inline-toggle">
                <b>Administration</b>
              </span>
            </div>
            <div class="d-inline-block text-left" v-else-if="$root.$data.visible_settings">
              <span class="d-block inline-toggle">
                <b>Settings</b>
              </span>
            </div>
          </template>
          <b-dropdown-item
            v-for="channel in $root.$data.channels"
            v-bind="channel.id"
            :to="{name: 'chat', params: { channel_id: channel.id }}"
          >{{channel.name}}</b-dropdown-item>
          <b-dropdown-item href="#">
            Pheasant
            <span class="badge badge-pill badge-danger">4</span>
          </b-dropdown-item>
          <b-dropdown-divider />
          <b-dropdown-item v-b-modal.modal-channels>Create new channel</b-dropdown-item>
          <b-dropdown-divider />
          <b-dropdown-item :to="{name: 'settings'}">Settings</b-dropdown-item>
          <b-dropdown-item :to="{name: 'admin'}">Administration</b-dropdown-item>
        </b-dropdown>
      </div>

      <div class="right">
        <form class="form-inline">
          <input
            class="form-control mr-sm-2 search"
            type="search"
            placeholder="Search"
            aria-label="Search"
          />

          <button class="btn btn-outline-brand" type="button">
            <i class="fas fa-search"></i>
          </button>

          <form class="btn-group form-inline line-left ml-2 pl-2">
            <button class="btn btn-outline-brand" type="button" v-b-modal.modal-add-user>
              <i class="fas fa-users-cog"></i>
            </button>
            <button class="btn btn-outline-brand" type="button">
              <i class="fas fa-columns"></i>
            </button>
            <button class="btn btn-outline-brand-muted" type="button">
              <i class="far fa-bell"></i>
            </button>
          </form>
        </form>
      </div>
    </nav>
    <b-modal id="modal-channels" title="Create a new channel">
      <form>
        <div class="form-group">
          <label for="name">Name</label>
          <input
            type="name"
            class="form-control"
            id="name"
            placeholder="my-secret-project"
            v-model="channel_form.name"
          />
        </div>
        <div class="form-check">
          <input
            class="form-check-input"
            type="checkbox"
            value
            id="public"
            v-model="channel_form.public"
          />
          <label
            class="form-check-label"
            for="public"
          >This is a public channel that can be joined freely.</label>
          <small
            id="publicHelp"
            class="form-text text-muted"
          >Channels can be public or private. Public channels can be read and joined by everyone, while private channels require an invitation.</small>
        </div>
      </form>
      <template v-slot:modal-footer>
        <button type="submit" class="btn btn-primary" v-on:click="createChannel">Submit</button>
      </template>
    </b-modal>
    <b-modal id="modal-add-user" :title="'Users of channel ' + getChannel().name">
      <div class="row">
        <table class="table table-hover">
          <tbody>
            <tr v-for="member in getChannel().users">
              <th scope="row">@{{member.username}}</th>
              <td>{{member.first_name}}</td>
              <td>
                <a href="#">Remove from this channel</a>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <form>
        <div class="form-group">
          <label for="name">Add a person</label>
          <input
            type="name"
            class="form-control"
            id="name"
            placeholder="Username or email"
            v-model="channel_user_name"
          />
        </div>
      </form>
      <template v-slot:modal-footer>
        <button type="submit" class="btn btn-primary" v-on:click="addUserToChannel">Submit</button>
      </template>
    </b-modal>
  </div>
</template>
<script>
import Vue from "vue";
import VueMarkdown from "vue-markdown";
import axios from "axios";

Vue.use(VueMarkdown);

export default {
  name: "menu-bar",
  props: {},
  data() {
    return { channel_form: {}, channel_user_name: "" };
  },
  created() {
    if ((this.token != null) & (this.token != undefined)) {
      localStorage.token = this.token;
    } else {
      this.token = localStorage.token;
    }

    axios.defaults.baseURL = process.env.VUE_APP_SERVER_BASE;
    axios.defaults.headers.common["Authorization"] = "Bearer " + this.token;

    let _this = this;

    axios
      .get("channels")
      .then(function(response) {
        _this.$root.$data.channels = response.data;
      })
      .catch(function(error) {
        console.log(error);
      });
  },
  methods: {
    createChannel() {
      let formData = new FormData();

      formData.append("name", this.channel_form.name);
      formData.append("public", this.channel_form.public);

      let _this = this;
      axios
        .post("channels", formData, {
          headers: {
            "Content-Type": "multipart/form-data"
          }
        })
        .then(function(response) {
          _this.$router.push({
            name: "chat",
            params: { channel_id: response.data.id }
          });

          //this.messages.push(msg);
        })
        .catch(function(response) {
          console.log("FAILURE!!");
          console.log(response);
        });
    },
    addUserToChannel() {
      let formData = new FormData();

      formData.append("username", this.channel_user_name);
      formData.append("channel_id", this.$root.$data.visible_channel_id);

      let _this = this;
      axios
        .post("channels/add_user", formData, {
          headers: {
            "Content-Type": "multipart/form-data"
          }
        })
        .then(function(response) {
          //TODO refresh table
          //this.messages.push(msg);
        })
        .catch(function(response) {
          console.log("FAILURE!!");
          console.log(response);
        });
    },
    getChannel() {
      let channel_id = this.$root.$data.visible_channel_id;
      for (let channel_key in this.$root.$data.channels) {
        if (this.$root.$data.channels[channel_key]["id"] == channel_id)
          return this.$root.$data.channels[channel_key];
      }
    }
  }
};
</script>
<style lang="scss">
@import "../style.scss";

.navbar {
  height: 60px;
  border-bottom: 1px solid rgba(0, 0, 0, 0.125);
  background-color: darken($jerboa_color4, 23%);
  flex-wrap: nowrap !important;

  .line-left {
    border-left: 1px solid darken($jerboa_color4, 17%);
  }

  .navbar-brand {
    img {
      margin-top: -5px;
    }
  }

  .dropdown-toggle:after {
    content: unset;
  }

  .inline-toggle:after {
    display: inline-block;
    margin-left: 0.255em;
    vertical-align: 0.255em;
    content: "";
    border-top: 0.3em solid;
    border-right: 0.3em solid transparent;
    border-bottom: 0;
    border-left: 0.3em solid transparent;
  }

  .badge-danger {
    background-color: $jerboa_color1;
  }

  .btn-outline-brand {
    color: lighten($jerboa_color5, 25%);
    //border-color: lighten($jerboa_color5, 25%);

    &:hover {
      color: lighten($jerboa_color5, 35%);
    }
  }
  .btn-outline-brand-muted {
    color: darken($jerboa_color5, 35%);
    //border-color: lighten($jerboa_color5, 25%);

    &:hover {
      color: darken($jerboa_color5, 25%);
    }
  }

  .dropdown-toggle {
    color: lighten($jerboa_color5, 30%);
    &:hover {
      color: lighten($jerboa_color5, 25%);
    }
  }

  color: lighten($jerboa_color5, 30%);

  .search {
    border: none;
    background-color: darken($jerboa_color4, 17%);
    color: lighten($jerboa_color5, 30%);

    &:focus {
      background-color: darken($jerboa_color4, 13%);
      border: none;
      -webkit-box-shadow: none;
      -webkit-border: none;
      color: lighten($jerboa_color5, 30%);
    }

    ::-webkit-search-cancel-button {
      color: lighten($jerboa_color5, 30%);
    }
  }
}

.modal-body {
  .row {
    margin-top: -17px;

    .table {
      border-bottom: 1px solid #dee2e6;
    }
  }
}
</style>
