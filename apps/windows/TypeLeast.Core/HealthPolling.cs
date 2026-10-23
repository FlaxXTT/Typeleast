namespace TypeLeast.Core;

// HealthPolling.cs - how often the app asks the local service how it is. Often while something is
// changing that the user is watching (the service starting, a speech model loading or downloading),
// rarely otherwise: a service that exits is noticed at once anyway (the process exit event), so an
// idle app need not wake up every few seconds. Opening the window always asks at once.
public static class HealthPolling
{
    public static readonly TimeSpan Busy = TimeSpan.FromSeconds(2), Idle = TimeSpan.FromSeconds(30);

    /// <summary>History retention and expired recordings are tidied this often (and after each dictation).</summary>
    public static readonly TimeSpan Housekeeping = TimeSpan.FromHours(1);

    public static TimeSpan Interval(bool serviceUp, string? speechPhase, string? operationPhase) =>
        !serviceUp || speechPhase is "loading" or "downloading" || operationPhase is "loading" or "downloading" ? Busy : Idle;
}
