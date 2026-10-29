using System.Text;
using System.Text.Json;
using TypeLeast.Core;

internal static class PersonalizationPolicyTests
{
    public static void Run(Action<string,bool,string> check)
    {
        void Assert(string name,bool value)=>check(name,value,"");
        var root=Path.Combine(Path.GetTempPath(),"typeleast-policy-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
        try {
            var cipher=TestHistoryProtection.Shared;
            var policy=new {version=1,disabled=true,excluded=Array.Empty<string>(),rules=new[]{new {id="fake-rule",heard="Acmee",word="Acme",enabled=true}}};
            var body=ServiceClient.DictateBody(new byte[]{1,2},new[]{"Acme"},personalization:policy);
            using var metadata=JsonDocument.Parse(body.Body.AsMemory(0,body.DictionaryBytes));
            Assert("policy travels once in local request metadata",metadata.RootElement.EnumerateArray().Count(x=>x.TryGetPropertySafe("personalization"))==1);
            var large=ServiceClient.DictateBody(new byte[]{1,2},Enumerable.Repeat(new string('字',120),2000).ToArray(),personalization:policy);
            Assert("oversized optional metadata does not drop audio",large.DictionaryBytes<256*1024&&large.Body.AsSpan(large.Body.Length-2).SequenceEqual(new byte[]{1,2}));
            using var safe=JsonDocument.Parse(large.Body.AsMemory(0,large.DictionaryBytes));Assert("oversized metadata disables personalization safely",safe.RootElement[0].GetProperty("personalization").GetProperty("disabled").GetBoolean());
            var privateSettingsPath=Path.Combine(root,"vocabulary.json");
            var privateSettings=new AppSettings {DictionaryEntries=new(){WordEntry.Parse("PrivateFixtureTerm")!},WordSuggestions=new(){new WordSuggestion {Word="CandidateFixture",HeardAs="fixture"}},DismissedSuggestions=new(){"DismissedFixture"}};
            privateSettings.Save(privateSettingsPath,cipher);
            var encoded=File.ReadAllText(privateSettingsPath);
            Assert("settings vocabulary and old candidates are encrypted",!encoded.Contains("PrivateFixtureTerm")&&!encoded.Contains("CandidateFixture")&&!encoded.Contains("DismissedFixture"));
            Assert("encrypted vocabulary roundtrips",AppSettings.Load(privateSettingsPath,cipher).DictionaryEntries.Single().Word=="PrivateFixtureTerm");
            cipher.Fail=true;try {try{privateSettings.Save(privateSettingsPath,cipher);}catch(System.Security.Cryptography.CryptographicException){}Assert("failed encryption preserves previous settings",File.ReadAllText(privateSettingsPath)==encoded);}finally{cipher.Fail=false;}
            using(var json=JsonDocument.Parse(encoded)){var changed=System.Text.Json.Nodes.JsonNode.Parse(encoded)!.AsObject();changed["protectedVocabulary"]=Convert.ToBase64String(new byte[32]);File.WriteAllText(privateSettingsPath,changed.ToJsonString());}
            var brokenSettings=AppSettings.Load(privateSettingsPath,cipher);Assert("unreadable vocabulary blocks settings overwrite",brokenSettings.PersistenceBlocked);
        } finally {Directory.Delete(root,true);}
    }
    private static bool TryGetPropertySafe(this JsonElement value,string name)=>value.ValueKind==JsonValueKind.Object&&value.TryGetProperty(name,out _);
}
