<template>
  <div class="message-container pt-2">
    <img
      class="avatar"
      src="https://ca.slack-edge.com/T7738P6P3-U76USER16-330ec1edea98-72"
      v-if="!incremental"
    />
    <div class="message">
      <div class="header" v-if="!incremental">
        <span class="font-weight-bold">{{msg.sender}}</span>
        <span class="font-weight-light text-muted ml-2">{{msg.sent_time}}</span>
      </div>

      <div class="content mt-0" v-bind:style="incremental ? 'margin-left: 31pt' : ''">
        <vue-markdown>{{this.msg.message}}</vue-markdown>
      </div>
    </div>
  </div>
</template>

<script>
import Vue from "vue";
import VueMarkdown from "vue-markdown";
Vue.use(VueMarkdown);

export default {
  name: "message",
  data() {
    return {};
  },
  components: {
    VueMarkdown
  },
  props: {
    incremental: {
      type: Boolean
    },
    msg: {
      type: Object
    }
  },
  methods: {
    mounted() {}
  }
};
</script>

<style lang="scss">
.message-container {
  border-top: 1px solid #eff0f1;
  display: inline-flex;
  margin-bottom: -4pt;
  line-height: 1;
  .avatar {
    height: 26pt;
    line-height: 26pt;
    width: 26pt;
    position: relative;
    display: inline-block;
    vertical-align: unset;
    margin-right: 5pt;
    border-radius: 3pt;
  }

  .message {
    display: inline-block;

    .content {
      line-height: 1.5;
    }
    .content,
    .header {
      display: block;
    }

    img {
      margin-top: 10px;
      max-width: 90%;
      background: #fff;
      padding: 0.5rem;
      box-shadow: 0 0.2rem 1.2rem rgba(0, 0, 0, 0.1);
    }

    pre {
      padding-left: 4px;
      margin-left: 5px;
      margin-top: 10px;
      border-left: 4px solid #3498db;
      border-radius: 2px;
    }
  }
}
</style>
