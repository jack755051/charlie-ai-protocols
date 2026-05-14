// ${PROJECT_NAME_PASCAL} WebAPI host (minimal API + Controllers).
// Read BACKEND_PORT / FEEDBACK_USE_POSTGRES / FEEDBACK_ADMIN_BEARER
// from env; never hardcode ports or secrets.

using ${PROJECT_NAME_PASCAL}.Application;
using ${PROJECT_NAME_PASCAL}.Infrastructure;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();

builder.Services.AddSingleton<IFeedbackStore, ${STORE_DEFAULT}>();

builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(p =>
        p.AllowAnyOrigin().AllowAnyHeader().AllowAnyMethod());
});

var app = builder.Build();
app.UseCors();
app.MapControllers();
app.MapGet("/api/health", () => Results.Ok(new { status = "ok" }));

var port = Environment.GetEnvironmentVariable("BACKEND_PORT") ?? "8080";
app.Run("http://0.0.0.0:" + port);
