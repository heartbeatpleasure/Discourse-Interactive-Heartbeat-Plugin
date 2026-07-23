export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("interactiveHeartbeatEvents", {
      path: "/interactive-heartbeat-events",
    });
  },
};
