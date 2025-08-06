import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "humanmark-content",
  after: "inject-discourse-objects",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");

    if (!siteSettings.humanmark_enabled) {
      return;
    }

    const hasContentProtection =
      siteSettings.humanmark_protect_posts ||
      siteSettings.humanmark_protect_topics ||
      siteSettings.humanmark_protect_messages;

    if (!hasContentProtection) {
      return;
    }

    withPluginApi((api) => {
      // Intercept composer save to add verification
      api.composerBeforeSave(() => {
        const composer = api.container.lookup("service:composer").model;
        const verification = api.container.lookup("service:verification");

        // Skip verification if editing
        if (composer.editingPost) {
          return Promise.resolve();
        }

        // Determine context based on action
        let context;
        if (composer.action === "createTopic") {
          context = "topic";
        } else if (composer.action === "privateMessage") {
          context = "message";
        } else {
          context = "post";
        }

        // Only verify if this context is protected and no receipt exists
        if (verification.isRequired(context) && !composer.humanmark_receipt) {
          return verification
            .verify(context)
            .then((receipt) => {
              if (receipt) {
                composer.set("humanmark_receipt", receipt);
              }
            })
            .catch((error) => {
              if (error.message === "CANCELLED") {
                throw new Error("Verification required");
              }
              throw error;
            });
        }

        return Promise.resolve();
      });

      // Ensure receipt is serialized when creating posts
      api.serializeOnCreate("humanmark_receipt");
    });
  },
};
