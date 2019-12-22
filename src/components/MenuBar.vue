<template>
  <nav class="navbar fixed-top navbar-dark">
    <div class="left">
      <a class="navbar-brand" href="#">
        <img class="mt-1 ml-2" src="/icon.png" alt width="30" height="30" />
      </a>
      <b-dropdown id="dropdown-right" left variant="white" class="m-2 navbar-brand">
        <template v-slot:button-content>
          <i class="fas fa-hashtag"></i> Main channel
        </template>
        <b-dropdown-item :to="{name: 'chat', params: { channel_id: '1' }}">#1</b-dropdown-item>
        <b-dropdown-item :to="{name: 'chat', params: { channel_id: 'general' }}">#general</b-dropdown-item>
        <b-dropdown-item href="#">
          Pheasant
          <span class="badge badge-pill badge-danger">4</span>
        </b-dropdown-item>
        <b-dropdown-divider />
        <b-dropdown-item :to="{name: 'settings'}">Settings</b-dropdown-item>
        <b-dropdown-item :to="{name: 'admin'}">Administration</b-dropdown-item>
      </b-dropdown>
    </div>

    <div class="center">
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
      </form>
    </div>

    <div class="right">
      <form class="btn-group form-inline">
        <button class="btn btn-outline-brand" type="button">
          <i class="fas fa-caret-square-left"></i>
        </button>
        <button class="btn btn-outline-brand" type="button">
          <i class="fas fa-columns"></i>
        </button>
        <button class="btn btn-outline-brand" type="button">
          <i class="fas fa-caret-square-right"></i>
        </button>
      </form>
    </div>
  </nav>
</template>
<script>
import Vue from "vue";
import VueMarkdown from "vue-markdown";

Vue.use(VueMarkdown);

export default {
  name: "menu-bar",
  props: {},
  data() {
    return {};
  },
  mounted() {},
  methods: {}
};
</script>
<style lang="scss">
@import "../style.scss";

.navbar {
  height: 60px;
  border-bottom: 1px solid rgba(0, 0, 0, 0.125);
  background-color: darken($jerboa_color4, 23%);

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
</style>
