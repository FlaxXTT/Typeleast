using System.Text.Json.Serialization;
namespace TypeLeast.Core;
public sealed class PersonalizationReference {
    public string Kind { get; set; }="";
    public string Source { get; set; }="";
    public string SourceId { get; set; }="";
    public string? Word { get; set; }
    public string? Heard { get; set; }
    public string? Label { get; set; }
}
public sealed class PersonalizationReplacement {
    public string Id { get; set; }="";
    public string? Heard { get; set; }
    public string? Word { get; set; }
    public string? Reason { get; set; }
}
public sealed class PersonalizationTrace {
    public bool Disabled { get; set; }
    public List<PersonalizationReference> References { get; set; }=new();
    public List<PersonalizationReplacement> Replacements { get; set; }=new();
    public List<PersonalizationReplacement> Blocked { get; set; }=new();
    public bool Restored { get; set; }
    public string? BeforeReplacements { get; set; }
}
