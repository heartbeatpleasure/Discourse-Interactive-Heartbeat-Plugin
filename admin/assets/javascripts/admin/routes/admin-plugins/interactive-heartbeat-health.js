import DiscourseRoute from "discourse/routes/discourse";
import { i18n } from "discourse-i18n";

export default class AdminPluginsInteractiveHeartbeatHealthRoute extends DiscourseRoute {
  titleToken() {
    return i18n("admin.interactive_heartbeat.health.title");
  }

  setupController(controller) {
    super.setupController(...arguments);
    controller?.resetState?.();
    controller?.loadHealth?.();
  }
}
