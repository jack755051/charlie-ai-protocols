# ${PROJECT_ID} frontend container (Component Fast Path placeholder).
# The fast-path delivers `lib/feedback/*` and `components/feedback/*`
# as importable library code; a real Next.js host app is the
# consumer's responsibility. This Dockerfile ships a tiny Node
# static server so the smoke runtime has a `frontend` service that
# returns 200 — replace with a Next.js build when the consumer
# wires the library into a host app.

FROM node:20-alpine
WORKDIR /app

# Library code copied so it is inspectable inside the container
# (volume-mount sharing or downstream tooling) but NOT served by
# the static server. Host apps consume it via `npm install`.
COPY ./lib/feedback ./lib/feedback
COPY ./components/feedback ./components/feedback

# Placeholder landing page — the only thing actually served on
# the smoke port. Updated by render-time token substitution so
# operators can confirm the rendered project_id reached the
# container.
COPY ./index.html ./index.html

# http-server reads the -p flag at start time; FRONTEND_PORT
# defaults to 3000 if compose does not override it.
RUN npm install --no-audit --no-fund --silent --global http-server@14

ENV FRONTEND_PORT=3000
EXPOSE 3000

CMD ["sh", "-c", "http-server -p ${FRONTEND_PORT:-3000} -s ."]
