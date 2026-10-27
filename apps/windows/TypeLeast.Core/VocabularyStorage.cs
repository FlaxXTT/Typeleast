using System.Text.Json;
using System.Text.Json.Nodes;
namespace TypeLeast.Core;

/// <summary>Retired vocabulary is removed without decrypting or exporting it.</summary>
public static class VocabularyStorage {
    public static string Encode(AppSettings settings,IHistoryProtection? protection=null) {
        var document=JsonSerializer.SerializeToNode(settings,Json.Options)!.AsObject();
        foreach(var key in document.Select(x=>x.Key).Where(x=>new[]{"dictionaryEntries","wordSuggestions","dismissedSuggestions","words","protectedVocabulary"}.Contains(x,StringComparer.OrdinalIgnoreCase)).ToArray())document.Remove(key);
        document["vocabularyRemoved"]=true;
        return document.ToJsonString(Json.Options);
    }
    public static void Decode(JsonElement document,AppSettings settings,IHistoryProtection? protection=null) {
        settings.DictionaryEntries=new();settings.WordSuggestions=new();settings.DismissedSuggestions=new();settings.Words=new();
    }
}
