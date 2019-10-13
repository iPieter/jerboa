<template>
  <div class="dashboard-tile column info-tile p-centered pt-2" :class="color">
    <div style="flex: 1">
      <div style=" display: flex; justify-content: center">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          x="0px"
          y="0px"
          width="40"
          height="40"
          viewBox="0 0 210 210"
        >
          <g
            fill="none"
            fill-rule="nonzero"
            stroke="none"
            stroke-width="1"
            stroke-linecap="butt"
            stroke-linejoin="miter"
            stroke-miterlimit="10"
            stroke-dasharray
            stroke-dashoffset="0"
            font-family="none"
            font-weight="none"
            font-size="none"
            text-anchor="none"
            style="mix-blend-mode: normal"
          >
            <path d="M0,192v-192h192v192z" fill="none" />
            <g fill="#ffffff">
              <g id="surface1">
                <path
                  d="M80.04,-0.12c-1.635,0.255 -2.925,1.5 -3.24,3.12c-6,28.425 -18.195,49.17 -29.16,68.52c-10.965,19.35 -20.88,37.44 -20.88,60.24c0,29.67 19.5,49.215 45.48,58.56c0.39,0.15 0.675,0.465 1.08,0.6c1.845,0.735 3.945,-0.03 4.89,-1.77c0.945,-1.74 0.45,-3.915 -1.17,-5.07c-6.66,-5.145 -15.48,-17.265 -15.48,-26.88c0,-10.56 2.13,-17.175 5.16,-24.6c2.37,-5.79 5.28,-12.615 7.92,-21c8.46,10.56 9.72,23.04 9.72,23.04c0.075,1.8 1.35,3.3 3.12,3.675c1.755,0.375 3.525,-0.51 4.32,-2.115c0,0 13.335,-27.915 12.12,-60.72c21.855,23.085 30.495,45.48 30.36,63.96c-0.15,21.45 -11.4,38.28 -21.96,45.48c-1.455,1.05 -2.025,2.94 -1.365,4.605c0.645,1.68 2.34,2.7 4.125,2.475c27.75,-4.035 50.16,-29.28 50.16,-60.6c0,-22.395 -6.48,-42.195 -19.92,-62.64c-13.44,-20.445 -33.78,-41.685 -62.04,-67.8c-0.78,-0.735 -1.815,-1.125 -2.88,-1.08c-0.12,0 -0.24,0 -0.36,0zM82.68,11.28c25.305,23.685 44.19,43.575 56.16,61.8c12.795,19.47 18.48,37.395 18.48,58.32c0,21.54 -12.045,39.24 -28.56,47.76c7.56,-10.05 13.32,-23.535 13.44,-39.72c0.165,-23.01 -11.01,-50.235 -39.72,-77.04c-1.23,-1.08 -3,-1.29 -4.455,-0.51c-1.44,0.765 -2.25,2.37 -2.025,3.99c3.645,24.615 -2.535,43.665 -6.96,55.08c-2.34,-6.405 -6.33,-14.025 -13.56,-20.28c-1.035,-0.885 -2.46,-1.17 -3.75,-0.75c-1.29,0.405 -2.28,1.47 -2.61,2.79c-2.865,11.685 -6.555,19.23 -9.72,27c-3.165,7.77 -5.76,15.81 -5.76,27.48c0,6.66 2.4,13.02 5.76,18.6c-15.18,-9.465 -24.72,-23.88 -24.72,-44.04c0,-20.52 8.88,-37.14 19.8,-56.4c10.065,-17.745 21.51,-37.815 28.2,-64.08z"
                />
              </g>
            </g>
          </g>
        </svg>
      </div>
      <h1 class="p-centered">{{value}}</h1>
    </div>

    <div class="sub-tile">
      <h5>{{title}}</h5>
      <h4 class>{{secondValue}}</h4>
    </div>
  </div>
</template>
<script>
import Vue from "vue";

export default {
  name: "stats-tile",
  props: {
    title: {
      type: String,
      required: true
    },
    value: {
      type: String,
      required: true
    },
    secondValue: {
      type: String,
      required: true
    },
    color: {
      type: String,
      required: true
    }
  },
  data() {
    return {};
  },
  mounted() {},
  methods: {}
};
</script>
<style scoped>
.info-tile {
  color: rgb(255, 255, 255);
  display: flex;
  flex-direction: column;
}

.blue-tile {
  background-color: rgba(52, 152, 219, 1);
}

.purple-tile {
  background-color: rgba(142, 68, 173, 1);
}

.orange-tile {
  background-color: rgba(230, 126, 34, 1);
}

.info-tile h1 {
  font-weight: 600;
}
.info-tile h1,
.info-tile h4,
.info-tile h5 {
  text-align: center;
}

.sub-tile {
  background-color: rgba(255, 255, 255, 0.2);
  margin: -10pt;
  padding-bottom: 10pt;
  padding-top: 5pt;
  flex: 0;
}

.dashboard-tile {
  border: 2px solid rgb(240, 242, 245);
  border-radius: 10px;
  margin: 10px;
  -webkit-box-shadow: 6px 6px 26px 0px rgba(240, 242, 245, 1);
  -moz-box-shadow: 6px 6px 26px 0px rgba(240, 242, 245, 1);
  box-shadow: 6px 6px 26px 0px rgba(240, 242, 245, 1);
  padding: 10px 10px 2px 10px;
}

.dashboard-tile h1 {
  margin-bottom: 20px;
}
</style>
