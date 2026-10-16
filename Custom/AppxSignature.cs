// Validate APPX/MSIX content through the Windows SIP without installing a
// certificate. CERT_E_UNTRUSTEDROOT is handled separately by the caller.
using System;
using System.Runtime.InteropServices;

public static class CustomAppxSignature
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct FileInfo
    {
        public uint Size;
        [MarshalAs(UnmanagedType.LPWStr)] public string Path;
        public IntPtr File;
        public IntPtr KnownSubject;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TrustData
    {
        public uint Size;
        public IntPtr PolicyCallback;
        public IntPtr SipClient;
        public uint UIChoice;
        public uint RevocationChecks;
        public uint UnionChoice;
        public IntPtr FileInfo;
        public uint StateAction;
        public IntPtr StateData;
        public IntPtr UrlReference;
        public uint ProviderFlags;
        public uint UIContext;
        public IntPtr SignatureSettings;
    }

    [DllImport("wintrust.dll", ExactSpelling = true, PreserveSig = true)]
    private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);

    public static uint Verify(string path)
    {
        var file = new FileInfo { Size = (uint)Marshal.SizeOf(typeof(FileInfo)), Path = path };
        IntPtr filePointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(FileInfo)));
        Marshal.StructureToPtr(file, filePointer, false);
        var data = new TrustData {
            Size = (uint)Marshal.SizeOf(typeof(TrustData)), UIChoice = 2,
            UnionChoice = 1, FileInfo = filePointer, StateAction = 1,
            ProviderFlags = 0x1010 // cache-only retrieval, no online revocation check
        };
        var action = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");
        try { return unchecked((uint)WinVerifyTrust(new IntPtr(-1), ref action, ref data)); }
        finally {
            data.StateAction = 2;
            WinVerifyTrust(new IntPtr(-1), ref action, ref data);
            Marshal.DestroyStructure(filePointer, typeof(FileInfo));
            Marshal.FreeHGlobal(filePointer);
        }
    }
}
