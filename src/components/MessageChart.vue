import { Bar } from "vue-chartjs";

export default {
  extends: Bar,
  props: ["data", "label", "users"],
  watch: {
    data: function() {
      this.data_loaded = true;
      this.update_chart();
    },
  },
  data: {
    users_loaded: false,
    data_loaded: false,
  },
  methods: {
    getRandomColor() {
      var letters = "0123456789ABCDEF";
      var color = "#";
      for (var i = 0; i < 6; i++) {
        color += letters[Math.floor(Math.random() * 16)];
      }
      return color;
    },

    update_chart() {
      let _this = this;
      console.log(_this.users);
      console.log("update to data");
      // Overwriting base render method with actual data.
      this.renderChart({
        labels: _this.data.map((d) => d["Date"]),
        datasets: _this.users.map((user) => ({
          label: user.first_name,
          backgroundColor: this.getRandomColor(),
          data: _this.data
            .filter((d) => d["Username"] == user.display_name)
            .map((d) => ({ x: d["Date"], y: d["Count"] })),
        })),
      });
    },
  },
};
