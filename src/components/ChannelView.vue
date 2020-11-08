<template>
  <div :class="$parent.file_preview == '' ? 'col-xl-6 col-md-8 col-sm-12 mx-auto' : 'col-sm-12'" v-if="messages.length > 0">
    <message
      v-for="message in messages"
      :messagesProp="message.messages"
      :key="message.id"
      :ref="`msg_${message.id}`"
      :emojis="custom_emojis"
      :token="$root.$data.token"
      :id="message.id"
      :incremental="message.incremental"
      :sender="$root.$data.users[message.sender]"
    ></message>

    <div
      class="text-muted message-container"
      v-for="(message, index) in unacked_messages"
      v-bind:key="index"
    >
      <img
        class="avatar"
        :src="base + 'files?f=' + $root.$data.user.profile_image"
      />
      <div class="message">
        <span class="font-weight-bold">
          {{ $root.$data.user.first_name }}
          <b-spinner small label="Small Spinner" type="grow"></b-spinner>
        </span>
        <div class="content" v-if="message.message_type == 'TEXT_MESSAGE'">
          <vue-markdown
            :emoji="true"
            class="content-msg"
            :source="message.message"
          ></vue-markdown>
        </div>
        <div class="content" v-else>
          {{ message.message.message }}
          <b-card class="m-2 files-card upload-card">
            <b-card-title class="m-3">
              <b-spinner
                variant="secondary"
                small
                class="mr-1 mb-1"
                label="Small Spinner"
              ></b-spinner
              >Uploading your files
            </b-card-title>
            <b-progress
              :value="message.uploadPercentage"
              max="100"
              class="mb-0"
              :label="`${((message.uploadPercentage ) * 100).toFixed(2)}%`"
            ></b-progress>
          </b-card>
        </div>
      </div>
    </div>
  </div>
  <div class="col-xl-6 col-md-8 col-sm-12 mx-auto empty-channel" v-else>
    <div class="row pt-4">
      <img src="/start_writing.png" class="col-md-3 mx-auto" />
    </div>
    <div class="text-center pt-4">
      <h1 class="">This is the beginning of this channel</h1>
      <h2 class="">Start writing by saying hello.</h2>
    </div>
  </div>
</template>

<script>
import Vue from "vue";
import VueMarkdown from "vue-markdown";

Vue.use(VueMarkdown);
import Message from "./Message";

Vue.extend(Message);

export default {
  components: { Message, VueMarkdown },

  data: function() {
    return {
      custom_emojis: [],
      base: "/",
    };
  },
  props: {
    messages: {
      type: Array,
    },
    unacked_messages: {},
  },
  beforeMount() {
    this.base = process.env.VUE_APP_SERVER_BASE;
  },
};
</script>

<style lang="scss">
@import "../style.scss";

.empty-channel {
  img {
    height: 100%;
  }

  h1,
  h2 {
    color: darken($jerboa_color4, 10%);
  }
}
</style>
