namespace TypeLeast.Core;

public interface ICredentialStore
{
    string? Read(string account);
    bool Write(string account, string value);
}
