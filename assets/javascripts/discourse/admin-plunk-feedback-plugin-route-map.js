// The path is prefixed: child routes of adminPlugins.show share one
// namespace across every installed plugin (/admin/plugins/:plugin_id/<path>),
// so a bare word would collide with any other plugin that used it.
export default {
  resource: "admin.adminPlugins.show",

  path: "/plugins",

  map() {
    this.route("discourse-plunk-email-feedback", { path: "plunk-feedback" });
  },
};
