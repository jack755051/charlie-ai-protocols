// ${PROJECT_ID} rating control (UI adapter layer).
// shadcn-ui + lucide icons are intentionally allowed under
// components/, NOT under lib/feedback. The core layer stays
// adapter-agnostic so other UI runtimes can swap this file.

"use client";

import { useState } from "react";
import { Star } from "lucide-react";
import type { FeedbackRating } from "../../lib/feedback";

export interface RatingControlProps {
  value?: FeedbackRating;
  onChange: (rating: FeedbackRating) => void;
  disabled?: boolean;
}

const STAR_VALUES: ReadonlyArray<FeedbackRating> = [1, 2, 3, 4, 5];

export function RatingControl({ value, onChange, disabled }: RatingControlProps) {
  const [hovered, setHovered] = useState<FeedbackRating | null>(null);
  const active = hovered ?? value ?? 0;

  return (
    <div
      role="radiogroup"
      aria-label="Rating"
      data-testid="feedback-rating"
      className="flex gap-2"
      style={{ opacity: disabled ? 0.4 : 1 }}
    >
      {STAR_VALUES.map((n) => {
        const filled = n <= active;
        return (
          <button
            key={n}
            type="button"
            role="radio"
            aria-checked={value === n}
            aria-label={"Rate " + n + " of 5"}
            data-testid={"feedback-rating-" + n}
            disabled={disabled}
            onMouseEnter={() => !disabled && setHovered(n)}
            onMouseLeave={() => setHovered(null)}
            onFocus={() => !disabled && setHovered(n)}
            onBlur={() => setHovered(null)}
            onClick={() => !disabled && onChange(n)}
            style={{
              background: "transparent",
              border: "none",
              padding: 0,
              cursor: disabled ? "not-allowed" : "pointer",
            }}
          >
            <Star
              size={24}
              strokeWidth={2}
              fill={filled ? "var(--color-primary)" : "transparent"}
              color={filled ? "var(--color-primary)" : "var(--color-border)"}
            />
          </button>
        );
      })}
    </div>
  );
}
