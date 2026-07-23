export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("interactiveHeartbeat", { path: "/interactive-heartbeat" });
  },
};
