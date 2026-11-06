// voxl passwords in Windows Credential Manager ("voxl viewer: https://host:port" under Windows
// Credentials), the Windows counterpart of the Mac's Keychain.
using System.Runtime.InteropServices;
using System.Text;

namespace VoxlViewer;

static class Credentials
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL
    {
        public uint Flags, Type;
        public string TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias, UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredReadW(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredWriteW(ref CREDENTIAL credential, uint flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredDeleteW(string target, uint type, uint flags);
    [DllImport("advapi32.dll")] static extern void CredFree(IntPtr buffer);

    const uint CRED_TYPE_GENERIC = 1, CRED_PERSIST_LOCAL_MACHINE = 2;

    public static string Target(Uri uri) => "voxl viewer: " + uri.GetLeftPart(UriPartial.Authority);

    public static (string User, string Password)? Read(string target)
    {
        if (!CredReadW(target, CRED_TYPE_GENERIC, 0, out var p)) return null;
        try
        {
            var c = Marshal.PtrToStructure<CREDENTIAL>(p);
            var password = c.CredentialBlobSize == 0 ? "" : Marshal.PtrToStringUni(c.CredentialBlob, (int)c.CredentialBlobSize / 2);
            return (c.UserName ?? "", password);
        }
        finally
        {
            CredFree(p);
        }
    }

    public static void Write(string target, string user, string password)
    {
        var blob = Encoding.Unicode.GetBytes(password);
        var p = Marshal.AllocHGlobal(Math.Max(blob.Length, 1));
        try
        {
            Marshal.Copy(blob, 0, p, blob.Length);
            var c = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC,
                TargetName = target,
                CredentialBlobSize = (uint)blob.Length,
                CredentialBlob = p,
                Persist = CRED_PERSIST_LOCAL_MACHINE,
                UserName = user.Length > 0 ? user : null,
            };
            CredWriteW(ref c, 0);
        }
        finally
        {
            Marshal.Copy(new byte[blob.Length], 0, p, blob.Length);
            Marshal.FreeHGlobal(p);
        }
    }

    public static void Delete(string target) => CredDeleteW(target, CRED_TYPE_GENERIC, 0);
}
