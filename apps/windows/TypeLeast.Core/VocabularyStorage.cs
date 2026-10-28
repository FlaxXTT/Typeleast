using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
namespace TypeLeast.Core;

/// <summary>Vocabulary travels inside the atomic settings file as a protected payload.</summary>
public static class VocabularyStorage
{
    private sealed class Archive {
        public int Version { get; set; }=1;
        public List<WordEntry> Entries { get; set; }=new();
        public List<WordSuggestion> Suggestions { get; set; }=new();
        public List<string> Dismissed { get; set; }=new();
    }
    public static string Encode(AppSettings settings,IHistoryProtection? protection=null)
    {
        var plain=JsonSerializer.SerializeToUtf8Bytes(new Archive {Entries=settings.DictionaryEntries.Count>0?settings.DictionaryEntries:settings.Words.Select(WordEntry.FromLegacy).OfType<WordEntry>().ToList(),Suggestions=settings.WordSuggestions,Dismissed=settings.DismissedSuggestions},Json.Options);
        try {
            var sealedData=(protection??new DpapiHistoryProtection()).Protect(plain);
            var document=JsonSerializer.SerializeToNode(settings,Json.Options)!.AsObject();
            foreach(var key in document.Select(x=>x.Key).Where(x=>new[]{"dictionaryEntries","wordSuggestions","dismissedSuggestions","words"}.Contains(x,StringComparer.OrdinalIgnoreCase)).ToArray())document.Remove(key);
            document["protectedVocabulary"]=Convert.ToBase64String(sealedData);
            return document.ToJsonString(Json.Options);
        }finally{CryptographicOperations.ZeroMemory(plain);}
    }
    public static void Decode(JsonElement document,AppSettings settings,IHistoryProtection? protection=null)
    {
        JsonElement encoded=default;var found=false;
        foreach(var property in document.EnumerateObject())if(property.Name.Equals("protectedVocabulary",StringComparison.OrdinalIgnoreCase)){encoded=property.Value;found=true;break;}
        if(!found)return; // Original plain settings remain readable until their next successful save.
        if(encoded.ValueKind!=JsonValueKind.String)throw new JsonException("Invalid protected vocabulary");
        byte[]? plain=null;
        try {
            plain=(protection??new DpapiHistoryProtection()).Unprotect(Convert.FromBase64String(encoded.GetString()??""));
            var archive=JsonSerializer.Deserialize<Archive>(plain,Json.Options);
            if(archive is not {Version:1}||archive.Entries is null||archive.Suggestions is null||archive.Dismissed is null)throw new JsonException();
            settings.DictionaryEntries=archive.Entries;settings.WordSuggestions=archive.Suggestions;settings.DismissedSuggestions=archive.Dismissed;
            settings.Words=new();
        }catch(FormatException){throw new JsonException("Invalid protected vocabulary");}
        finally{if(plain is not null)CryptographicOperations.ZeroMemory(plain);}
    }
}
