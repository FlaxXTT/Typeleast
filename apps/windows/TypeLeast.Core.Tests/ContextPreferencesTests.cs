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
            Assert("tutorial rejects missing model evidence",!progress.Accept(response,2));
            response.Model="fictional-model";response.Ms=new MsBreakdown {Transcribe=10,Polish=20,Total=30};
            response.Fallback=true;
            Assert("fallback cannot pass tutorial",!progress.Accept(response,2)&&!progress.Complete);response.Fallback=false;
            Assert("tutorial accepts real-chain evidence",progress.Accept(response,2)&&progress.Complete);
            response.ContextOnly=true;
            Assert("context-only response is never insertable",response.InsertableText=="");
        } finally {Directory.Delete(directory,true);}
    }
}
