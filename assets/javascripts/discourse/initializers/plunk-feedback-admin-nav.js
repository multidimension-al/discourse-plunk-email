import getURL from "discourse/lib/get-url";
import { withPluginApi } from "discourse/lib/plugin-api";

const PLUGIN_ID = "discourse-plunk-email";
const ROUTE = "adminPlugins.show.discourse-plunk-email-feedback";
const URL = "/admin/plugins/discourse-plunk-email/plunk-feedback";

// Adds the feedback page to the plugin's admin nav once the router can
// actually resolve it. Core's adminPlugins.show.index redirects to the first
// nav entry unconditionally, so advertising a route that is missing (admin
// routes load in a separate chunk) would break the plugin's admin page.
export default {
  name: "plunk-feedback-admin-nav",

  initialize(container) {
    const currentUser = container.lookup("service:current-user");
    const router = container.lookup("service:router");
    if (!currentUser?.admin || !router) {
      return;
    }

    const register = () => {
      if (!this.routeExists(router)) {
        return;
      }

      router.off("routeWillChange", register);
      router.off("routeDidChange", register);

      withPluginApi((api) => {
        api.addAdminPluginConfigurationNav(PLUGIN_ID, [
          { label: "discourse_plunk.admin.nav.feedback", route: ROUTE },
        ]);
      });
    };

    router.on("routeWillChange", register);
    router.on("routeDidChange", register);
  },

  routeExists(router) {
    try {
      return router.recognize(getURL(URL))?.name === ROUTE;
    } catch {
      return false;
    }
  },
};
