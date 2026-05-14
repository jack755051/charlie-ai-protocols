// ${PROJECT_NAME_PASCAL} feedback HTTP surface.
// Wraps every response in ApiResponse<T> / PaginatedResponse<T>;
// bearer token is required for the admin list endpoint.

using Microsoft.AspNetCore.Mvc;
using ${PROJECT_NAME_PASCAL}.Application;

namespace ${PROJECT_NAME_PASCAL}.Api;

public sealed record ApiResponse<T>(int StatusCode, string Message, T Data);
public sealed record PageMeta(int Page, int PageSize, int Total);
public sealed record PaginatedResponse<T>(int StatusCode, string Message, IReadOnlyList<T> Data, PageMeta Meta);

public sealed record SubmitFeedbackRequest(int Rating, string Comment);

[ApiController]
[Route("api/feedback")]
public sealed class FeedbackController : ControllerBase
{
    private readonly IFeedbackStore _store;

    public FeedbackController(IFeedbackStore store)
    {
        _store = store;
    }

    [HttpPost]
    public async Task<ActionResult<ApiResponse<FeedbackEntry>>> Submit(
        [FromBody] SubmitFeedbackRequest request,
        CancellationToken ct)
    {
        if (request is null)
            return BadRequest(new ApiResponse<object?>(400, "missing body", null));
        if (request.Rating is < 1 or > 5)
            return BadRequest(new ApiResponse<object?>(400, "rating must be 1..5", null));
        if (string.IsNullOrWhiteSpace(request.Comment))
            return BadRequest(new ApiResponse<object?>(400, "comment is required", null));

        var entry = await _store.AddAsync(
            new FeedbackSubmission(request.Rating, request.Comment.Trim()), ct);
        return Ok(new ApiResponse<FeedbackEntry>(200, "ok", entry));
    }

    [HttpGet]
    public async Task<ActionResult<PaginatedResponse<FeedbackEntry>>> List(
        [FromQuery(Name = "page")] int page = 1,
        [FromQuery(Name = "pageSize")] int pageSize = 20,
        CancellationToken ct = default)
    {
        var expected = Environment.GetEnvironmentVariable("FEEDBACK_ADMIN_BEARER");
        if (!string.IsNullOrEmpty(expected))
        {
            var header = Request.Headers["Authorization"].ToString();
            if (header != "Bearer " + expected)
                return Unauthorized(new ApiResponse<object?>(401, "unauthorized", null));
        }

        var result = await _store.ListAsync(page, pageSize, ct);
        return Ok(new PaginatedResponse<FeedbackEntry>(
            200, "ok", result.Entries,
            new PageMeta(page, pageSize, result.Total)));
    }
}
