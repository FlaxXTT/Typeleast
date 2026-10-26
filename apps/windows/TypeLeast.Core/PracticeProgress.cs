using System.Text.RegularExpressions;
namespace TypeLeast.Core;

public sealed class PracticeProgress
{
    private readonly HashSet<int> completed = new();
    public IReadOnlySet<int> Completed => completed;
    public string MarkerId { get; private set; } = "";
    private string? reviewText;
    public bool ReviewReady => reviewText is not null;
    public bool Complete => completed.SetEquals(new[] { 0, 1, 2 });
    public bool Accept(DictateResponse response, double seconds, int exercise, string markerId)
    {
        if (exercise==2) reviewText=null;
        if (seconds<0.6 || response.Fallback || response.Clarification is not null || response.ContextOnly
            || string.IsNullOrWhiteSpace(response.Raw) || string.IsNullOrWhiteSpace(response.Text)
            || string.IsNullOrEmpty(response.Model) || response.Ms?.Transcribe is null || response.Ms.Polish is null) return false;
        switch(exercise) {
            case 0:
                if(!Regex.IsMatch(response.Raw,@"不对|说错了|改成|改为|no[ ,]+wait|I mean|rather",RegexOptions.IgnoreCase)) return false;
                if(!response.Text.Any(char.IsDigit))return false;
                completed.Add(0); return true;
            case 1:
                if(response.Explanation is not { Used:true, Segments:>0 } receipt || receipt.MarkerId!=markerId || !ExplanationMarkers.Ids.Contains(markerId)) return false;
                foreach(var english in new[] {false,true}) {
                    var words=ExplanationMarkers.Words(markerId,english);
                    if(response.Text.Contains(words.Start,StringComparison.OrdinalIgnoreCase)||response.Text.Contains(words.End,StringComparison.OrdinalIgnoreCase))return false;
                }
                completed.Add(1); MarkerId=markerId; return true;
            case 2:reviewText=response.Text;return true;
            default:return false;
        }
    }
    public bool ConfirmReview(string original,string corrected)
    {
        if(reviewText is null||reviewText!=original||string.IsNullOrWhiteSpace(corrected)||corrected==original||corrected.Length>4000)return false;
        completed.Add(2);reviewText=null;return true;
    }
}
