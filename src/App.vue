<template>
  <div>
    <MenuBar />
    <router-view class="view"></router-view>
  </div>
</template>

<script>
import Vue from "vue";
import MenuBar from "./components/MenuBar";

import "bootstrap/dist/css/bootstrap.css";
import "bootstrap-vue/dist/bootstrap-vue.css";
import "./style.scss";

import axios from "axios";
export default {
  name: "app",
  components: { MenuBar },
  data() {
    return {};
  },
  methods: {},
  mounted() {}
};
</script>

<style lang="scss" scoped>
.view {
  margin-top: 60px;
}
</style>