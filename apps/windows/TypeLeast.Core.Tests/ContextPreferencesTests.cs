using TypeLeast.Core;

internal static class ContextPreferencesTests
{
    public static void Run(Action<string, bool, string> check)
    {
        AppSettings LoadSettings(string path) => AppSettings.Load(path, TestHistoryProtection.Shared);
        void Assert(string name,bool value)=>check(name,value,"");
        var directory=Path.Combine(Path.GetTempPath(),"typeleast-context-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try {
            var settingsPath=Path.Combine(directory,"settings.json");
            Assert("fresh Windows installation requires real tutorial",LoadSettings(settingsPath).NeedsPractice);
            File.WriteAllText(settingsPath,"{\"strength\":\"prompt\"}");
            Assert("legacy Windows settings do not force tutorial",!LoadSettings(settingsPath).NeedsPractice);
            new AppSettings {OnboardingDone=true,PracticeGateRequired=false}.Save(settingsPath, TestHistoryProtection.Shared);
            Assert("finished tutorial persists",!LoadSettings(settingsPath).NeedsPractice);
            var progress=new PracticeProgress();
            var response=new DictateResponse {Raw="周三，不对，周四，不超过三页",Text="周四，不超过 3 页。"};
            Assert("a short recording is asked again",progress.Accept(response,0.3)==PracticeProgress.Outcome.TooShort);
            response.Fallback=true;
            Assert("a failed cleanup does not pass",progress.Accept(response,2)==PracticeProgress.Outcome.NotCleaned&&!progress.Complete);response.Fallback=false;
            response.Text="周四交，不超过三页。";
            Assert("any recognised and cleaned sentence passes",progress.Accept(response,2)==PracticeProgress.Outcome.Passed&&progress.Complete);
            response.ContextOnly=true;
            Assert("context-only response is never insertable",response.InsertableText=="");
        } finally {Directory.Delete(directory,true);}
    }
}
