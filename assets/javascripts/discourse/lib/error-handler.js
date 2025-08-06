import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

export default class HumanmarkErrorHandler {
  static handle(error, context = {}) {
    // Only log errors in development/debug mode
    if (window.Discourse?.Environment === "development") {
      console.error("[Humanmark] Error:", error, context);
    }

    if (error.name === "AbortError") {
      return this.handleTimeout();
    }

    if (
      error.message === "CANCELLED" ||
      error.name === "VerificationCancelledError"
    ) {
      return this.handleCancellation(context);
    }

    if (error.jqXHR?.status === 422) {
      return this.handleValidationError(error);
    }

    if (error.jqXHR?.status === 403) {
      return this.handleForbidden();
    }

    // Default: use Discourse's error popup
    popupAjaxError(error);
  }

  static handleTimeout() {
    bootbox.alert(i18n("humanmark.errors.timeout"));
  }

  static handleCancellation() {
    // Silently handle cancellation - user chose to cancel
  }

  static handleValidationError(error) {
    const message =
      error.jqXHR?.responseJSON?.errors?.[0] ||
      i18n("humanmark.errors.validation");
    bootbox.alert(message);
  }

  static handleForbidden() {
    bootbox.alert(i18n("humanmark.errors.forbidden"));
  }
}
