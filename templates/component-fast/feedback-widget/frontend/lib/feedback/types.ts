// ${PROJECT_ID} feedback domain types.
// Pure data shapes — no UI imports allowed in this directory tree.

export type FeedbackRating = 1 | 2 | 3 | 4 | 5;

export interface FeedbackEntry {
  id: string;
  rating: FeedbackRating;
  comment: string;
  createdAt: string;
}

export interface FeedbackSubmission {
  rating: FeedbackRating;
  comment: string;
}

export interface PageMeta {
  page: number;
  pageSize: number;
  total: number;
}

export interface ApiResponse<T> {
  statusCode: number;
  message: string;
  data: T;
}

export interface PaginatedResponse<T> {
  statusCode: number;
  message: string;
  data: T[];
  meta: PageMeta;
}
