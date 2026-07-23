export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("interactiveHeartbeatHealth", {
      path: "/interactive-heartbeat-health",
    });
  },
};
