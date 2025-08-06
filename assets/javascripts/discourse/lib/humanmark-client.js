import { ajax } from "discourse/lib/ajax";
import loadScript from "discourse/lib/load-script";

export default class HumanmarkClient {
  constructor(siteSettings, currentUser = null) {
    this.siteSettings = siteSettings;
    this.currentUser = currentUser;
    this.sdkLoaded = false;
    this.sdkConstructor = null;
  }

  async ensureSDKLoaded() {
    if (this.sdkLoaded) {
      return;
    }

    const sdkUrl = this.siteSettings.humanmark_sdk_url;
    const integrity = this.siteSettings.humanmark_sdk_integrity;

    if (!integrity || integrity.length < 10) {
      throw new Error("SDK integrity hash is required for security");
    }

    await loadScript(sdkUrl, {
      crossOrigin: "anonymous",
      integrity,
    });

    // Handle various SDK export patterns
    let SdkConstructor = window.HumanmarkSdk;
    if (typeof SdkConstructor === "object" && !SdkConstructor.prototype) {
      SdkConstructor =
        SdkConstructor.HumanmarkSdk || SdkConstructor.default || SdkConstructor;
    }

    if (typeof SdkConstructor !== "function") {
      throw new Error("Humanmark SDK constructor not found");
    }

    this.sdkConstructor = SdkConstructor;
    this.sdkLoaded = true;
  }

  async createFlow(context) {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 15000);

    try {
      const response = await ajax("/humanmark/flows", {
        type: "POST",
        data: { context },
        signal: controller.signal,
      });

      return response;
    } catch (error) {
      if (error.name === "AbortError") {
        throw new Error("Request timeout - please try again");
      }
      throw error;
    } finally {
      clearTimeout(timeoutId);
    }
  }

  async performVerification(token) {
    await this.ensureSDKLoaded();

    const sdk = new this.sdkConstructor({
      apiKey: this.siteSettings.humanmark_api_key,
      challengeToken: token,
      baseUrl: this.siteSettings.humanmark_api_url || "https://humanmark.io",
      theme: this.siteSettings.humanmark_theme || "light",
    });

    return await sdk.verify();
  }

  async verify(context) {
    try {
      // Create flow - backend will determine if verification is actually required
      const flow = await this.createFlow(context);

      // Backend says verification not required (context not protected or user bypassed)
      if (!flow.required) {
        return null;
      }

      // Perform verification
      const receipt = await this.performVerification(flow.token);

      return receipt;
    } catch (error) {
      if (
        error.message === "CANCELLED" ||
        error.name === "VerificationCancelledError"
      ) {
        throw error;
      }

      // Only log errors in development
      if (window.Discourse?.Environment === "development") {
        console.error("[Humanmark] Verification error:", error);
      }
      throw error;
    }
  }

  isRequired(context) {
    if (!this.siteSettings.humanmark_enabled) {
      return false;
    }

    // Check if context is protected
    const settingsMap = {
      post: this.siteSettings.humanmark_protect_posts,
      topic: this.siteSettings.humanmark_protect_topics,
      message: this.siteSettings.humanmark_protect_messages,
    };

    if (!settingsMap[context]) {
      return false;
    }

    // Check bypass settings
    if (this.currentUser) {
      // Bypass for staff
      if (this.siteSettings.humanmark_bypass_staff && this.currentUser.staff) {
        return false;
      }

      // Bypass for trust level
      const bypassTrustLevel = this.siteSettings.humanmark_bypass_trust_level;
      if (
        bypassTrustLevel !== undefined &&
        this.currentUser.trust_level >= bypassTrustLevel
      ) {
        return false;
      }
    }

    return true;
  }
}
