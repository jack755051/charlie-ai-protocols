// ${PROJECT_NAME_PASCAL} in-memory feedback store.
// Default implementation for dev / test / smoke. The Postgres
// adapter (gated by FEEDBACK_USE_POSTGRES=true) is a P1c addition
// and intentionally absent here.

using System.Collections.Concurrent;
using ${PROJECT_NAME_PASCAL}.Application;

namespace ${PROJECT_NAME_PASCAL}.Infrastructure;

public sealed class InMemoryFeedbackStore : IFeedbackStore
{
    private readonly ConcurrentDictionary<Guid, FeedbackEntry> _entries = new();

    public Task<FeedbackEntry> AddAsync(FeedbackSubmission submission, CancellationToken ct)
    {
        var entry = new FeedbackEntry(
            Guid.NewGuid(),
            submission.Rating,
            submission.Comment,
            DateTimeOffset.UtcNow);
        _entries[entry.Id] = entry;
        return Task.FromResult(entry);
    }

    public Task<FeedbackPage> ListAsync(int page, int pageSize, CancellationToken ct)
    {
        if (page < 1) page = 1;
        if (pageSize < 1) pageSize = 20;
        var ordered = _entries.Values
            .OrderByDescending(e => e.CreatedAt)
            .ToArray();
        var slice = ordered
            .Skip((page - 1) * pageSize)
            .Take(pageSize)
            .ToArray();
        return Task.FromResult(new FeedbackPage(slice, ordered.Length));
    }
}
