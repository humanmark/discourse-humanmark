import contentIntegration from "../integrations/content-integration";

export default {
  name: "humanmark",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");

    if (!siteSettings.humanmark_enabled) {
      return;
    }

    // Initialize content integration
    contentIntegration.initialize(container);
  },
};
