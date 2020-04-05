<template>
  <div>
    <div
      class="col-xl-6 col-md-8 col-sm-12 mx-auto "
      v-for="message in messages"
    >
      <message
        v-for="message in messages"
        :messagesProp="message.messages"
        :key="message.id"
        :ref="`msg_${message.id}`"
        :emojis="custom_emojis"
        :token="$root.$data.token"
        :id="message.id"
        :incremental="message.incremental"
        sender="Bob"
      ></message>
    </div>
  </div>
</template>

<script>
import Vue from "vue";
import Message from "./Message";

var MessageClass = Vue.extend(Message);

export default {
  components: { Message },

  data: function() {
    return {
      custom_emojis: []
    };
  },
  props: {
    messages: {
      type: Array
    }
  }
};
</script>

<style></style>
