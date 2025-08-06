import discourseConfig from "@discourse/lint-configs/eslint";

export default [
  ...discourseConfig,
  {
    ignores: ["node_modules/**", "vendor/**", "coverage/**", "tmp/**"],
  },
  {
    languageOptions: {
      globals: {
        Discourse: "readonly",
        I18n: "readonly",
        bootbox: "readonly",
        $: "readonly",
        jQuery: "readonly",
      },
    },
    rules: {
      // Plugin-specific overrides
      "no-console": ["error", { allow: ["warn", "error", "log"] }],
    },
  },
];