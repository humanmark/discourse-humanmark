module.exports = {
  extends: ["@discourse/lint-configs/stylelint"],
  rules: {
    // Custom rules for this plugin
    "selector-class-pattern": [
      "^(humanmark-|hm-)[a-z0-9-]+$",
      {
        message: "Class names should start with 'humanmark-' or 'hm-' prefix",
      },
    ],
    "color-hex-length": "long", // Use long hex colors for clarity
  },
};
