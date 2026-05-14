# ${PROJECT_ID} — Component States Reference

Render-time substitution: `${PROJECT_ID}` / `${COMPONENT_TYPE}`.

## RatingControl

| State | Trigger | Visual treatment |
|---|---|---|
| idle | mount | five outlined stars, none highlighted |
| hover | pointer enter on star N | stars 1..N filled with `--color-primary` |
| selected | click star N | stars 1..N filled and locked; emits `onChange(N)` |
| disabled | parent `disabled=true` | stars rendered at 40% opacity, no pointer events |

## FeedbackForm

| State | Trigger | Visual treatment |
|---|---|---|
| idle | mount, no submission attempted | submit enabled iff rating and comment present |
| submitting | submit click → API in flight | submit shows spinner + `aria-busy=true`; inputs disabled |
| success | API returns 2xx | green confirmation banner; form fields reset |
| validation_error | client-side check failed | inline message under offending field; `aria-invalid=true` |
| server_error | API 4xx / 5xx / network error | top-of-form error banner with retry CTA |

## Layout contract

- All spacing pulled from `--spacing-*` vars in `design/theme.css`.
- All colors pulled from `--color-*` vars in `design/theme.css`.
- No hardcoded hex / px values in the rendered UI files.
