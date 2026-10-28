using System.Text;
using System.Text.Json;
using TypeLeast.Core;

internal static class PersonalizationPolicyTests
{
    public static void Run(Action<string,bool,string> check)
    {
        AppSettings LoadSettings(string path) => AppSettings.Load(path, TestHistoryProtection.Shared);
        void Assert(string name,bool value)=>check(name,value,"");
        var root=Path.Combine(Path.GetTempPath(),"typeleast-policy-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
        try {
            var path=Path.Combine(root,"preferences.sealed");var cipher=TestHistoryProtection.Shared;
            var preferences=new PreferenceExamples(path,cipher);
            using var contract=JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory,"personalization-v1.json")));
            foreach(var item in contract.RootElement.GetProperty("vocabularyCases").EnumerateArray()) {
                var word=WordEntry.Parse("Acme",item.GetProperty("heard").GetString()!,item.GetProperty("source").GetString()!)!;
                Assert("shared reference authority: "+item.GetProperty("id").GetString(),preferences.References(word)==item.GetProperty("reference").GetBoolean());
                Assert("shared replacement authority: "+item.GetProperty("id").GetString(),preferences.Replaces(word)==item.GetProperty("replacement").GetBoolean());
            }
            var rule=WordEntry.Parse("Acme","Acmee")!;
            Assert("old manual mapping is not an enabled rule",!preferences.Replaces(rule));
            Assert("explicit enablement grants a local rule",preferences.SetRule(rule,true)&&preferences.Replaces(rule));
            Assert("fullwidth exclusion pauses the rule",preferences.Exclude("ＡＣＭＥ")&&!preferences.Replaces(rule));
            preferences.Restore("ＡＣＭＥ");
            Assert("restoring exclusion preserves prior enablement",preferences.Replaces(rule));
            rule.HeardAs="Another";
            Assert("editing a rule requires fresh approval",!preferences.Replaces(rule));
            var automatic=WordEntry.Parse("Acme","","auto")!;
            Assert("automatic terms stay inactive",!preferences.References(automatic));
            preferences.SetReference(automatic.Id,true);
            Assert("user may confirm an old term",preferences.References(automatic));
            preferences.Exclude("Acme");Assert("all-source exclusion also pauses personal words",!preferences.References(automatic));
            var reload=new PreferenceExamples(path,cipher);
            Assert("encrypted exclusions and permissions persist",reload.IsExcluded("ACME")&&reload.WordStates.ContainsKey(automatic.Id));
            Assert("override archive is not plaintext",!Encoding.UTF8.GetString(File.ReadAllBytes(path)).Contains("ＡＣＭＥ"));
            var policy=reload.WirePolicy(new[]{rule},true);
            var body=ServiceClient.DictateBody(new byte[]{1,2},new[]{"Acme"},personalization:policy);
            using var metadata=JsonDocument.Parse(body.Body.AsMemory(0,body.DictionaryBytes));
            Assert("policy travels once in local request metadata",metadata.RootElement.EnumerateArray().Count(x=>x.TryGetPropertySafe("personalization"))==1);
            var large=ServiceClient.DictateBody(new byte[]{1,2},Enumerable.Repeat(new string('字',120),2000).ToArray(),personalization:policy);
            Assert("oversized optional metadata does not drop audio",large.DictionaryBytes<256*1024&&large.Body.AsSpan(large.Body.Length-2).SequenceEqual(new byte[]{1,2}));
            using var safe=JsonDocument.Parse(large.Body.AsMemory(0,large.DictionaryBytes));Assert("oversized metadata disables personalization safely",safe.RootElement[0].GetProperty("personalization").GetProperty("disabled").GetBoolean());
            var before=File.ReadAllBytes(path);cipher.Fail=true;
            try {Assert("failed encryption never enables a changed rule",!preferences.SetRule(rule,true)&&!preferences.Replaces(rule)&&File.ReadAllBytes(path).AsSpan().SequenceEqual(before));}finally{cipher.Fail=false;}
            var legacy=new PreferenceExample {HistoryId="legacy-fixture",Raw="请发报告",AiText="发送报告。",CorrectedText="请发报告。",Confirmed=true};
            File.WriteAllBytes(path,cipher.Protect(JsonSerializer.SerializeToUtf8Bytes(new[]{legacy},Json.Options)));
            var upgraded=new PreferenceExamples(path,cipher);Assert("old encrypted example array remains readable",upgraded.Entries.Count==1);
            upgraded.Exclude("Acme");Assert("old examples survive new archive save",new PreferenceExamples(path,cipher).Entries.Single().HistoryId==legacy.HistoryId);
            var privateSettingsPath=Path.Combine(root,"vocabulary.json");
            var privateSettings=new AppSettings {DictionaryEntries=new(){WordEntry.Parse("PrivateFixtureTerm")!},WordSuggestions=new(){new WordSuggestion {Word="CandidateFixture",HeardAs="fixture"}},DismissedSuggestions=new(){"DismissedFixture"}};
            privateSettings.Save(privateSettingsPath,cipher);
            var encoded=File.ReadAllText(privateSettingsPath);
            Assert("settings vocabulary and old candidates are encrypted",!encoded.Contains("PrivateFixtureTerm")&&!encoded.Contains("CandidateFixture")&&!encoded.Contains("DismissedFixture"));
            Assert("encrypted vocabulary roundtrips",AppSettings.Load(privateSettingsPath,cipher).DictionaryEntries.Single().Word=="PrivateFixtureTerm");
            cipher.Fail=true;try {try{privateSettings.Save(privateSettingsPath,cipher);}catch(System.Security.Cryptography.CryptographicException){}Assert("failed encryption preserves previous settings",File.ReadAllText(privateSettingsPath)==encoded);}finally{cipher.Fail=false;}
            using(var json=JsonDocument.Parse(encoded)){var changed=System.Text.Json.Nodes.JsonNode.Parse(encoded)!.AsObject();changed["protectedVocabulary"]=Convert.ToBase64String(new byte[32]);File.WriteAllText(privateSettingsPath,changed.ToJsonString());}
            var brokenSettings=AppSettings.Load(privateSettingsPath,cipher);Assert("unreadable vocabulary blocks settings overwrite",brokenSettings.PersistenceBlocked);
            var settingsPath=Path.Combine(root,"settings.json");File.WriteAllText(settingsPath,"{\"explanationMarkers\":\"background\"}");
            var settings=LoadSettings(settingsPath);Assert("old long marker selection migrates to short preset",settings.ExplanationMarkers=="note");
            settings.ExplanationMarkers="";settings.Save(settingsPath, TestHistoryProtection.Shared);Assert("later starts preserve marker opt-out",LoadSettings(settingsPath).ExplanationMarkers=="");
        } finally {Directory.Delete(root,true);}
    }
    private static bool TryGetPropertySafe(this JsonElement value,string name)=>value.ValueKind==JsonValueKind.Object&&value.TryGetProperty(name,out _);
}
