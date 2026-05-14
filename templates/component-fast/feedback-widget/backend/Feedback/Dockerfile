# ${PROJECT_NAME_PASCAL} backend image (Component Fast Path).
# Multi-stage build: SDK restores + publishes, ASP.NET runtime serves.
# The runtime listens on BACKEND_PORT (compose-supplied; default
# 8080) via Program.cs `app.Run("http://0.0.0.0:" + port)`. ASPNETCORE_URLS
# is intentionally NOT set so app.Run wins.

FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

COPY Feedback.csproj ./
RUN dotnet restore Feedback.csproj

COPY . .
RUN dotnet publish Feedback.csproj -c Release -o /app/publish --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app

COPY --from=build /app/publish .

# Default fallback; compose overrides BACKEND_PORT via the `environment:`
# block. Program.cs reads this env var and binds Kestrel accordingly.
ENV BACKEND_PORT=8080
EXPOSE 8080

ENTRYPOINT ["dotnet", "${PROJECT_NAME_PASCAL}.dll"]
