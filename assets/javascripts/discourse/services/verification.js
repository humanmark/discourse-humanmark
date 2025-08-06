import Service, { service } from "@ember/service";
import HumanmarkErrorHandler from "../lib/error-handler";
import HumanmarkClient from "../lib/humanmark-client";

export default class VerificationService extends Service {
  @service siteSettings;
  @service currentUser;

  constructor() {
    super(...arguments);
    this.client = new HumanmarkClient(this.siteSettings, this.currentUser);
  }

  async verify(context) {
    try {
      // Perform verification
      const receipt = await this.client.verify(context);
      return receipt;
    } catch (error) {
      HumanmarkErrorHandler.handle(error, { context });
      throw error;
    }
  }

  isRequired(context) {
    return this.client.isRequired(context);
  }
}
