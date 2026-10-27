using System.Text;
using System.Text.Json;
using TypeLeast.Core;
internal static class PersonalizationPolicyTests {
 public static void Run(Action<string,bool,string> check) {
  var dir=Path.Combine(Path.GetTempPath(),"typeleast-retirement-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(dir);
  void Assert(string name,bool value)=>check(name,value,"");
  try {
   var cipher=TestHistoryProtection.Shared;var path=Path.Combine(dir,"preferences.sealed");
   var example=new PreferenceExample {HistoryId="fake",Raw="请发报告",AiText="请发送报告。",CorrectedText="请发报告。",Confirmed=true};
   File.WriteAllBytes(path,cipher.Protect(JsonSerializer.SerializeToUtf8Bytes(new PersonalizationArchive {FormatVersion=2,Entries=new(){example},Excluded=new(){"Legacy"},RuleStates=new(){{"old",true}}},Json.Options)));
   var preferences=new PreferenceExamples(path,cipher);
   Assert("retired mixed archive preserves confirmed expressions",preferences.Entries.Count==1&&preferences.VocabularyRemovalComplete);
   var saved=JsonSerializer.Deserialize<PersonalizationArchive>(cipher.Unprotect(File.ReadAllBytes(path)),Json.Options)!;
   Assert("retired mixed archive drops vocabulary permissions",saved.FormatVersion==3&&saved.Excluded.Count==0&&saved.RuleStates.Count==0&&saved.WordStates.Count==0);
   var settingsPath=Path.Combine(dir,"settings.json");File.WriteAllText(settingsPath,"{\"words\":[\"Legacy\"],\"protectedVocabulary\":\"unreadable retired payload\",\"Language\":\"ja\"}");
   var malformedSettings=Path.Combine(dir,"malformed-settings.json");File.WriteAllText(malformedSettings,"{\"dictionaryEntries\":\"broken retired shape\",\"Language\":\"ko\"}");
   Assert("malformed retired words cannot reset unrelated settings",AppSettings.Load(malformedSettings,cipher).Language=="ko");
   var settings=AppSettings.Load(settingsPath,cipher);settings.Save(settingsPath,cipher);
   Assert("vocabulary removal preserves unrelated settings",settings.Language=="ja"&&settings.DictionaryEntries.Count==0);
   var text=File.ReadAllText(settingsPath);Assert("settings retain no retired payload",!text.Contains("Legacy")&&!text.Contains("protectedVocabulary")&&!text.Contains("unreadable retired payload"));
   File.WriteAllBytes(path,Encoding.UTF8.GetBytes("broken"));var original=File.ReadAllBytes(path);var broken=new PreferenceExamples(path,cipher);
   Assert("broken mixed archive is retained",!broken.VocabularyRemovalComplete&&File.ReadAllBytes(path).SequenceEqual(original));
   var response=JsonSerializer.Deserialize<DictateResponse>("{\"text\":\"\",\"raw\":\"source\",\"clarification\":{\"kind\":\"quality\",\"candidate\":\"draft\",\"reason\":\"incomplete-output\"}}",Json.Options)!;
   Assert("quality response is held with its candidate",response.Text==""&&response.Clarification?.Candidate=="draft");
  }finally{Directory.Delete(dir,true);}
 }
}
