namespace TypeLeast.Core;

/// <summary>One active operation; cancelled or superseded completions cannot deliver.</summary>
public sealed class OperationTracker
{
    private Lease? active;
    public Lease? Active => active;
    public Lease? TryBegin()
    {
        if (active is not null) return null;
        return active = new Lease();
    }
    public bool IsCurrent(Lease lease) => ReferenceEquals(active, lease) && !lease.Token.IsCancellationRequested;
    public void Cancel() { var old = active; active = null; old?.Cancel(); }
    public void Complete(Lease lease) { if (ReferenceEquals(active, lease)) active = null; lease.Dispose(); }
    public sealed class Lease : IDisposable
    {
        private readonly CancellationTokenSource source = new();
        public CancellationToken Token { get; }
        internal Lease() => Token = source.Token;
        internal void Cancel() => source.Cancel();
        public void Dispose() => source.Dispose();
    }
}

public sealed record DictationOptions(string Language, string Strength, string? TranslateTo, string? Variants,
    LlmRoute? Route, string InsertionMode = "autoPaste");

/// <summary>Reset only after a stable service run, not merely receipt of a ready line.</summary>
public sealed class RestartPolicy
{
    private int attempts;
    public double? Next(TimeSpan uptime)
    {
        if (uptime >= TimeSpan.FromSeconds(60)) attempts = 0;
        return ServiceLocator.RestartDelay(++attempts);
    }
    public void Reset() => attempts = 0;
}
