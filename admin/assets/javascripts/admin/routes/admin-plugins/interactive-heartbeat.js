import DiscourseRoute from "discourse/routes/discourse";
import { i18n } from "discourse-i18n";

export default class AdminPluginsInteractiveHeartbeatRoute extends DiscourseRoute {
  titleToken() {
    return i18n("admin.interactive_heartbeat.title");
  }
}
