// ${PROJECT_NAME_PASCAL} Application port for feedback persistence.
// Domain-side records live alongside the interface for this minimal
// slice; if the aggregate grows past a single record, split into
// Domain/Feedback.cs without touching this file's namespace.

namespace ${PROJECT_NAME_PASCAL}.Application;

public sealed record FeedbackEntry(
    Guid Id,
    int Rating,
    string Comment,
    DateTimeOffset CreatedAt);

public sealed record FeedbackSubmission(int Rating, string Comment);

public sealed record FeedbackPage(IReadOnlyList<FeedbackEntry> Entries, int Total);

public interface IFeedbackStore
{
    Task<FeedbackEntry> AddAsync(FeedbackSubmission submission, CancellationToken ct);
    Task<FeedbackPage> ListAsync(int page, int pageSize, CancellationToken ct);
}
