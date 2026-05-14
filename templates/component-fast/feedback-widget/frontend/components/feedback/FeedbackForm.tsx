// ${PROJECT_ID} feedback submission form (UI adapter layer).
// Imports shadcn-ui primitives + the rating control adapter; never
// reaches into raw DTO shapes (those stay in lib/feedback).

"use client";

import { useState, useTransition } from "react";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import {
  FeedbackApiClient,
  FeedbackValidationError,
  FeedbackServerError,
  FeedbackNetworkError,
  type FeedbackRating,
} from "../../lib/feedback";
import { RatingControl } from "./RatingControl";

type FormState =
  | { kind: "idle" }
  | { kind: "submitting" }
  | { kind: "success" }
  | { kind: "validation_error"; field?: string; message: string }
  | { kind: "server_error"; message: string };

export interface FeedbackFormProps {
  client?: FeedbackApiClient;
}

export function FeedbackForm({ client }: FeedbackFormProps = {}) {
  const apiClient = client ?? new FeedbackApiClient();
  const [rating, setRating] = useState<FeedbackRating | undefined>(undefined);
  const [comment, setComment] = useState("");
  const [state, setState] = useState<FormState>({ kind: "idle" });
  const [, startTransition] = useTransition();

  const reset = () => {
    setRating(undefined);
    setComment("");
  };

  const submit = async () => {
    if (rating === undefined) {
      setState({ kind: "validation_error", field: "rating", message: "Pick a rating first." });
      return;
    }
    setState({ kind: "submitting" });
    try {
      await apiClient.submit({ rating, comment });
      startTransition(() => {
        setState({ kind: "success" });
        reset();
      });
    } catch (err) {
      if (err instanceof FeedbackValidationError) {
        setState({ kind: "validation_error", field: err.field, message: err.message });
      } else if (err instanceof FeedbackServerError) {
        setState({ kind: "server_error", message: "Server rejected the submission (" + err.statusCode + ")." });
      } else if (err instanceof FeedbackNetworkError) {
        setState({ kind: "server_error", message: "Could not reach the server. Try again." });
      } else {
        setState({ kind: "server_error", message: "Unexpected error." });
      }
    }
  };

  const submitting = state.kind === "submitting";

  return (
    <form
      data-testid="feedback-form"
      onSubmit={(e) => {
        e.preventDefault();
        submit();
      }}
      style={{
        display: "flex",
        flexDirection: "column",
        gap: "var(--spacing-md)",
        fontFamily: "var(--font-family-sans)",
        color: "var(--color-foreground)",
      }}
    >
      <RatingControl value={rating} onChange={setRating} disabled={submitting} />
      <Textarea
        data-testid="feedback-comment"
        value={comment}
        onChange={(e) => setComment(e.currentTarget.value)}
        disabled={submitting}
        placeholder="Tell us what worked or didn't…"
        rows={4}
      />
      {state.kind === "validation_error" && (
        <p data-testid="feedback-validation" role="alert" style={{ color: "var(--color-destructive)" }}>
          {state.message}
        </p>
      )}
      {state.kind === "server_error" && (
        <p data-testid="feedback-server-error" role="alert" style={{ color: "var(--color-destructive)" }}>
          {state.message}
        </p>
      )}
      {state.kind === "success" && (
        <p data-testid="feedback-success" role="status" style={{ color: "var(--color-primary)" }}>
          Thanks for the feedback.
        </p>
      )}
      <Button data-testid="feedback-submit" type="submit" disabled={submitting} aria-busy={submitting}>
        {submitting ? "Submitting…" : "Submit feedback"}
      </Button>
    </form>
  );
}
