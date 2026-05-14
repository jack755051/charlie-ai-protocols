// ${PROJECT_ID} feedback API client (Domain port).
// Render-time substitution: ${API_BASE_URL} becomes the default base
// URL literal; callers can override via constructor options or
// process.env.NEXT_PUBLIC_API_BASE_URL at runtime.

import type {
  FeedbackEntry,
  FeedbackSubmission,
  ApiResponse,
  PaginatedResponse,
} from "./types";
import {
  FeedbackNetworkError,
  FeedbackServerError,
  FeedbackValidationError,
} from "./errors";
import type { FeedbackEntryDTO } from "./mapper";
import { mapFeedbackEntry, mapFeedbackEntries } from "./mapper";

const DEFAULT_BASE_URL = "${API_BASE_URL}";

export interface FeedbackApiClientOptions {
  baseUrl?: string;
  fetcher?: typeof fetch;
  adminBearer?: string;
}

export class FeedbackApiClient {
  private readonly baseUrl: string;
  private readonly fetcher: typeof fetch;
  private readonly adminBearer?: string;

  constructor(options: FeedbackApiClientOptions = {}) {
    this.baseUrl = (options.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
    this.fetcher = options.fetcher ?? fetch;
    this.adminBearer = options.adminBearer;
  }

  async submit(payload: FeedbackSubmission): Promise<FeedbackEntry> {
    if (!payload.comment || !payload.comment.trim()) {
      throw new FeedbackValidationError("comment is required", "comment");
    }

    let response: Response;
    try {
      response = await this.fetcher(this.url("/api/feedback"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
    } catch (cause) {
      throw new FeedbackNetworkError("feedback submission failed", cause);
    }

    if (!response.ok) {
      throw new FeedbackServerError(
        "submission rejected with status " + response.status,
        response.status,
      );
    }

    const envelope = (await response.json()) as ApiResponse<FeedbackEntryDTO>;
    return mapFeedbackEntry(envelope.data);
  }

  async list(page = 1, pageSize = 20): Promise<{ entries: FeedbackEntry[]; total: number }> {
    const headers: Record<string, string> = {};
    if (this.adminBearer) {
      headers.Authorization = "Bearer " + this.adminBearer;
    }

    let response: Response;
    try {
      response = await this.fetcher(
        this.url("/api/feedback?page=" + page + "&pageSize=" + pageSize),
        { method: "GET", headers },
      );
    } catch (cause) {
      throw new FeedbackNetworkError("feedback list failed", cause);
    }

    if (!response.ok) {
      throw new FeedbackServerError(
        "list rejected with status " + response.status,
        response.status,
      );
    }

    const envelope = (await response.json()) as PaginatedResponse<FeedbackEntryDTO>;
    return {
      entries: mapFeedbackEntries(envelope.data),
      total: envelope.meta.total,
    };
  }

  private url(path: string): string {
    return this.baseUrl + path;
  }
}
