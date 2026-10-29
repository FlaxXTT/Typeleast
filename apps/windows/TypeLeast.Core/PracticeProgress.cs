using System.Text.RegularExpressions;
namespace TypeLeast.Core;

public sealed class PracticeProgress
{
    public bool Complete { get; private set; }
    public bool Accept(DictateResponse response, double seconds)
    {
        if (seconds<0.6 || response.Fallback || response.Clarification is not null || response.ContextOnly
            || string.IsNullOrWhiteSpace(response.Raw) || string.IsNullOrWhiteSpace(response.Text)
            || string.IsNullOrEmpty(response.Model) || response.Ms?.Transcribe is null || response.Ms.Polish is null) return false;
        if(!Regex.IsMatch(response.Raw,@"不对|说错了|改成|改为|no[ ,]+wait|I mean|rather",RegexOptions.IgnoreCase)) return false;
        if(!response.Text.Any(char.IsDigit))return false;
        Complete=true; return true;
    }
}
