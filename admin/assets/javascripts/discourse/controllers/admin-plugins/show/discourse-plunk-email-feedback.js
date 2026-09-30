import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";

const BASE = "/admin/plugins/discourse-plunk-email/feedback";

export default class AdminPluginsShowDiscoursePlunkEmailFeedbackController extends Controller {
  @tracked status = null;
  @tracked events = [];
  @tracked total = 0;
  @tracked page = 0;
  @tracked pageSize = 50;
  @tracked query = "";
  @tracked statusFilter = "";
  @tracked kindFilter = "";
  @tracked selected = null;
  @tracked loading = false;
  @tracked loadFailed = false;
  @tracked reprocessing = false;

  get hasPreviousPage() {
    return this.page > 0;
  }

  get hasNextPage() {
    return (this.page + 1) * this.pageSize < this.total;
  }

  @action
  async load() {
    this.loadFailed = false;
    try {
      this.status = await ajax(`${BASE}/status`);
      await this.loadEvents();
    } catch {
      this.loadFailed = true;
    }
  }

  async loadEvents() {
    this.loading = true;
    try {
      const result = await ajax(`${BASE}/events`, {
        data: {
          q: this.query,
          status: this.statusFilter,
          kind: this.kindFilter,
          page: this.page,
        },
      });
      this.events = result.events;
      this.total = result.total;
      this.pageSize = result.page_size;
    } finally {
      this.loading = false;
    }
  }

  @action
  updateQuery(event) {
    this.query = event.target.value;
  }

  @action
  updateStatusFilter(event) {
    this.statusFilter = event.target.value;
    this.search();
  }

  @action
  updateKindFilter(event) {
    this.kindFilter = event.target.value;
    this.search();
  }

  @action
  submitSearch(event) {
    event?.preventDefault();
    this.search();
  }

  @action
  async search() {
    this.page = 0;
    try {
      await this.loadEvents();
    } catch {
      this.loadFailed = true;
    }
  }

  @action
  async previousPage() {
    this.page = Math.max(this.page - 1, 0);
    await this.loadEvents();
  }

  @action
  async nextPage() {
    this.page += 1;
    await this.loadEvents();
  }

  @action
  async showDetail(id) {
    try {
      const result = await ajax(`${BASE}/events/${id}`);
      this.selected = result.event;
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  closeDetail() {
    this.selected = null;
  }

  @action
  async reprocess(id) {
    this.reprocessing = true;
    try {
      const result = await ajax(`${BASE}/events/${id}/reprocess`, {
        type: "POST",
      });
      this.selected = result.event;
      this.status = await ajax(`${BASE}/status`);
      await this.loadEvents();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.reprocessing = false;
    }
  }
}
