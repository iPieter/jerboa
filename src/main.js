import Vue from "vue";
import App from "./App.vue";
import ChannelView from "./components/ChannelView";
import LoginView from "./components/LoginView";
import AdminView from "./components/AdminView";
import VueRouter from "vue-router";

Vue.use(VueRouter);

// 2. Define route components
// 3. Create the router
const router = new VueRouter({
  mode: "history",
  base: __dirname,
  routes: [
    { path: "/", component: ChannelView, props: true, name: "chat" },
    { path: "/admin", component: AdminView, props: true },
    { path: "/login", component: LoginView, props: true, name: "login" }
  ]
});

// 4. Create extended base Vue with router injected here (all
// children should inherit the same router).
new Vue({
  router,
  el: "#app",
  render: h => h(App)
});
