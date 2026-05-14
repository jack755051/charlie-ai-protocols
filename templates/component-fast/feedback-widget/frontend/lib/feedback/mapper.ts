// ${PROJECT_ID} DTO → Domain Model mapper.
// API envelope sub-shapes are kept narrow here so the api-client and
// UI layers never reach into raw DTO fields directly.

import type { FeedbackEntry, FeedbackRating } from "./types";

const ALLOWED_RATINGS: ReadonlySet<FeedbackRating> = new Set<FeedbackRating>([1, 2, 3, 4, 5]);

function coerceRating(value: unknown): FeedbackRating {
  if (typeof value === "number" && ALLOWED_RATINGS.has(value as FeedbackRating)) {
    return value as FeedbackRating;
  }
  return 1;
}

export interface FeedbackEntryDTO {
  id?: string | null;
  rating?: number | null;
  comment?: string | null;
  created_at?: string | null;
}

export function mapFeedbackEntry(dto: FeedbackEntryDTO): FeedbackEntry {
  return {
    id: dto.id ?? "",
    rating: coerceRating(dto.rating),
    comment: dto.comment ?? "",
    createdAt: dto.created_at ?? new Date(0).toISOString(),
  };
}

export function mapFeedbackEntries(items: ReadonlyArray<FeedbackEntryDTO>): FeedbackEntry[] {
  return items.map(mapFeedbackEntry);
}
