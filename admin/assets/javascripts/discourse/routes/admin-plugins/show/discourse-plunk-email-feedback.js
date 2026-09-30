import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsShowDiscoursePlunkEmailFeedback extends DiscourseRoute {
  setupController(controller, model) {
    super.setupController(controller, model);
    controller.load();
  }
}
