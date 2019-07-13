<template>
  <div class="message-container pt-1">
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

      <div
        class="content mt-1"
        v-html="msg.message.replace(':the-solution:', this.emoji())"
        v-bind:style="incremental ? 'margin-left: 31pt' : ''"
      ></div>
    </div>
  </div>
</template>

<script>
import Vue from "vue";

export default {
  name: "message",
  data() {
    return {};
  },
  components: {},
  props: {
    incremental: {
      type: Boolean
    },
    msg: {
      type: Object
    }
  },
  methods: {
    mounted() {},
    emoji: () => "🍷"
  }
};
</script>

<style lang="scss">
.message-container {
  display: inline-flex;
  margin-bottom: 4pt;
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
  }
}
</style>
