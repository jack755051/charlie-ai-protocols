// ${PROJECT_ID} feedback error hierarchy.
// UI layer maps these to user-facing messages; core / facade layers
// must only throw these (never raw Error / string) so error routing
// stays predictable.

export class FeedbackError extends Error {
  constructor(message: string, public readonly cause?: unknown) {
    super(message);
    this.name = "FeedbackError";
  }
}

export class FeedbackValidationError extends FeedbackError {
  constructor(message: string, public readonly field?: string) {
    super(message);
    this.name = "FeedbackValidationError";
  }
}

export class FeedbackNetworkError extends FeedbackError {
  constructor(message: string, cause?: unknown) {
    super(message, cause);
    this.name = "FeedbackNetworkError";
  }
}

export class FeedbackServerError extends FeedbackError {
  public readonly statusCode: number;
  constructor(message: string, statusCode: number) {
    super(message);
    this.name = "FeedbackServerError";
    this.statusCode = statusCode;
  }
}
