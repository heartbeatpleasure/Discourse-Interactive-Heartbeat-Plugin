export default function interactiveHeartbeat() {
  this.route("interactive-heartbeat", { path: "/interactive-heartbeat" });
  this.route("interactive-heartbeat-session", {
    path: "/interactive-heartbeat/sessions/:token",
  });
}
