<template>
  <vue-markdown
    :source="text"
    :html="false"
    :emoji="true"
    :prerender="preMessageRender"
    :postrender="postMessageRender"
  ></vue-markdown>
</template>

<script>
// Renders user-written message markdown; use this instead of <vue-markdown>.
// vue-markdown defaults to html: true and writes its output with innerHTML,
// so raw HTML stays disabled here and postMessageRender sanitizes the result.
import VueMarkdown from "vue-markdown";
import { preMessageRender, postMessageRender } from "../messageRender";

export default {
  name: "message-markdown",
  components: { VueMarkdown },
  props: {
    source: {
      default: "",
    },
  },
  computed: {
    text() {
      if (typeof this.source === "string") return this.source;
      return this.source == null ? "" : String(this.source);
    },
  },
  methods: {
    preMessageRender,
    postMessageRender,
  },
};
</script>
