using System.Text;
using TypeLeast.Core;

internal static class ContextPreferencesTests
{
    public static void Run(Action<string, bool, string> check)
    {
        void Assert(string name,bool value)=>check(name,value,"");
        var directory=Path.Combine(Path.GetTempPath(),"typeleast-context-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try {
            var settingsPath=Path.Combine(directory,"settings.json");
            Assert("fresh Windows installation requires real tutorial",AppSettings.Load(settingsPath).NeedsPractice);
            File.WriteAllText(settingsPath,"{\"strength\":\"prompt\"}");
            Assert("legacy Windows settings do not force tutorial",!AppSettings.Load(settingsPath).NeedsPractice);
            new AppSettings {OnboardingDone=true,PracticeGateRequired=false}.Save(settingsPath);
            Assert("finished tutorial persists",!AppSettings.Load(settingsPath).NeedsPractice);
            var path=Path.Combine(directory,"preferences.sealed");
            var protection=TestHistoryProtection.Shared;
            var examples=new PreferenceExamples(path,protection);
            examples.Offer("fictional-1","请把报告发给团队","请将报告发送给团队。","请发报告给团队。");
            Assert("observed revision is pending only",examples.Pending.Count==1&&examples.Entries.Count==0&&examples.WireExamples.Length==0&&!File.Exists(path));
            var item=examples.Pending[0];
            Assert("explicit confirmation saves encrypted example",examples.Confirm(item)&&examples.Pending.Count==0);
            Assert("encrypted preferences contain no plaintext",!Encoding.UTF8.GetString(File.ReadAllBytes(path)).Contains("请发报告"));
            Assert("encrypted preference survives reload",new PreferenceExamples(path,protection).Entries.Single().CorrectedText=="请发报告给团队。");
            examples.SetEnabled(item.Id,false);
            Assert("disabled preference never reaches request",examples.WireExamples.Length==0);
            examples.Offer("pending","报告","会议报告","报告摘要");examples.ClearPending();
            Assert("clear pending preserves confirmed records",examples.Pending.Count==0&&examples.Entries.Count==1);
            File.WriteAllBytes(path,Encoding.UTF8.GetBytes("corrupted fictional encrypted payload"));
            var broken=new PreferenceExamples(path,protection);
            Assert("unreadable preference cannot replace original",!broken.Confirm(item)&&Encoding.UTF8.GetString(File.ReadAllBytes(path))=="corrupted fictional encrypted payload");
            var progress=new PracticeProgress();
            var response=new DictateResponse {Raw="周三，不对，周四，不超过三页",Text="周四，不超过 3 页。"};
            Assert("tutorial rejects missing model evidence",!progress.Accept(response,2,0,"background"));
            response.Model="fictional-model";response.Ms=new MsBreakdown {Transcribe=10,Polish=20,Total=30};
            Assert("tutorial accepts real-chain evidence",progress.Accept(response,2,0,"background"));
            response.Fallback=true;
            Assert("fallback cannot pass tutorial",!progress.Accept(response,2,1,"background"));response.Fallback=false;
            response.Explanation=new ExplanationReceipt {Used=true,Segments=1,MarkerId="background"};
            Assert("receipt must match selected marker",!progress.Accept(response,2,1,"aside"));
            Assert("explanation exercise passes matching marker",progress.Accept(response,2,1,"background"));
            Assert("voice alone does not complete review",progress.Accept(response,2,2,"background")&&!progress.Complete);
            Assert("review requires latest output",!progress.ConfirmReview("other output","revision"));
            Assert("unchanged review cannot pass",!progress.ConfirmReview(response.Text,response.Text));
            Assert("confirmed review completes tutorial",progress.ConfirmReview(response.Text,response.Text+"请确认。")&&progress.Complete);
            response.ContextOnly=true;
            Assert("context-only response is never insertable",response.InsertableText=="");
        } finally {Directory.Delete(directory,true);}
    }
}
