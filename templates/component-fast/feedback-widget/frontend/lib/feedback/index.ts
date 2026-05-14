// ${PROJECT_ID} feedback domain public surface.
// Re-export only — no logic here so consumers can pin against
// `<this-package>/lib/feedback` without depending on internal layout.

export * from "./types";
export * from "./errors";
export * from "./mapper";
export * from "./api-client";
