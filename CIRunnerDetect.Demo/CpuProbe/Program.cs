// Machine-readable lines: NAME=1 (true), NAME=0 (false), NAME=-1 (not exposed / not resolvable).
// Targets net10.0. VPCLMULQDQ uses Pclmulqdq.V256.IsSupported (AVX2 path). PCLMULQDQ mirrors HashLib (SSSE3+).

using System.Reflection;
using System.Runtime.InteropServices;
using Armi = System.Runtime.Intrinsics.Arm;
using X86ni = System.Runtime.Intrinsics.X86;

namespace CpuProbe;

internal static class Program
{
    private static int Main()
    {
        var arch = RuntimeInformation.ProcessArchitecture;
        if (arch is Architecture.X64 or Architecture.X86)
        {
            PrintX86(arch);
        }
        else if (arch == Architecture.Arm64)
        {
            PrintArm64();
        }
        else if (arch == Architecture.Arm)
        {
            PrintArm32();
        }
        else
        {
            Console.WriteLine("ARCH=unknown");
        }

        return 0;
    }

    private static Type? ResolveIntrinsicType(string fullName)
    {
        var t = Type.GetType(fullName + ", System.Runtime.Intrinsics", throwOnError: false);
        if (t is not null)
            return t;

        // Intrinsics types may live in the intrinsics assembly or be type-forwarded from corelib.
        foreach (var asm in new[] { typeof(X86ni.Sse2).Assembly, typeof(object).Assembly })
        {
            t = asm.GetType(fullName, throwOnError: false);
            if (t is not null)
                return t;
        }

        foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
        {
            if (!string.Equals(asm.GetName().Name, "System.Runtime.Intrinsics", StringComparison.Ordinal))
                continue;
            t = asm.GetType(fullName, throwOnError: false);
            if (t is not null)
                return t;
        }

        return null;
    }

    /// <summary>1 = supported, 0 = not supported, -1 = type not present on this TFM/runtime.</summary>
    private static int GetIntrinsicTriState(string fullTypeName)
    {
        var t = ResolveIntrinsicType(fullTypeName);
        if (t is null)
            return -1;
        var p = t.GetProperty("IsSupported", BindingFlags.Public | BindingFlags.Static);
        if (p is null)
            return -1;
        return p.GetValue(null) is true ? 1 : 0;
    }

    private static void PrintX86(Architecture arch)
    {
        Console.WriteLine(arch == Architecture.X64 ? "ARCH=x64" : "ARCH=x86");

        Console.WriteLine($"SSE2={(X86ni.Sse2.IsSupported ? 1 : 0)}");
        Console.WriteLine($"SSSE3={(X86ni.Ssse3.IsSupported ? 1 : 0)}");
        Console.WriteLine($"AVX2={(X86ni.Avx2.IsSupported ? 1 : 0)}");

        var ssse3 = X86ni.Ssse3.IsSupported;
        var pcl = ssse3 && X86ni.Pclmulqdq.IsSupported;
        Console.WriteLine($"PCLMULQDQ={(pcl ? 1 : 0)}");

        // VPCLMULQDQ (256-bit): exposed as Pclmulqdq.V256.IsSupported on .NET 10+ (not a top-level Vpclmulqdq type).
        if (!X86ni.Avx2.IsSupported)
            Console.WriteLine("VPCLMULQDQ=0");
        else
            Console.WriteLine($"VPCLMULQDQ={(X86ni.Pclmulqdq.V256.IsSupported ? 1 : 0)}");

        Console.WriteLine($"AESNI={(X86ni.Aes.IsSupported ? 1 : 0)}");
        // Intel SHA extensions: still not a documented X86.Sha type in ref assemblies; probe at runtime.
        Console.WriteLine($"SHANI={GetIntrinsicTriState("System.Runtime.Intrinsics.X86.Sha")}");

        Console.WriteLine($"SIMDLVL={X86SimdLevel()}");
    }

    private static string X86SimdLevel()
    {
        if (X86ni.Avx2.IsSupported)
            return "avx2";
        if (X86ni.Ssse3.IsSupported)
            return "ssse3";
        if (X86ni.Sse2.IsSupported)
            return "sse2";
        return "scalar";
    }

    private static void PrintArm64()
    {
        Console.WriteLine("ARCH=arm64");
        
        Console.WriteLine($"NEON={(Armi.AdvSimd.IsSupported ? 1 : 0)}");

        // Experimental (SYSLIB5003) — suppressed in CpuProbe.csproj; see https://aka.ms/dotnet-warnings/SYSLIB5003
        Console.WriteLine($"SVE={(Armi.Sve.IsSupported ? 1 : 0)}");
        Console.WriteLine($"SVE2={(Armi.Sve2.IsSupported ? 1 : 0)}");

        Console.WriteLine($"AES={(Armi.Aes.IsSupported ? 1 : 0)}");
        Console.WriteLine($"SHA1={(Armi.Sha1.IsSupported ? 1 : 0)}");
        Console.WriteLine($"SHA256={(Armi.Sha256.IsSupported ? 1 : 0)}");
        Console.WriteLine($"SHA512={GetIntrinsicTriState("System.Runtime.Intrinsics.Arm.Sha512")}");
        Console.WriteLine($"SHA3={GetIntrinsicTriState("System.Runtime.Intrinsics.Arm.Sha3")}");
       
        Console.WriteLine($"CRC32={(Armi.Crc32.IsSupported ? 1 : 0)}");

        // PMULL (64-bit poly long, HWCAP_PMULL / FEAT_PMULL): Aes.PolynomialMultiplyWideningLower/Upper(UInt64) → A64 PMULL/PMULL2 on .1D (MS Learn). Gated by Arm.Aes.IsSupported.
        Console.WriteLine($"PMULL={ArmPoly64PmullProbe()}");

        Console.WriteLine($"SIMDLVL={ArmSimdLevel()}");
    }

    /// <summary>Maps to HashLib AArch64 PMULL (poly64 long): same gate .NET uses for Aes.PolynomialMultiplyWidening* (UInt64).</summary>
    private static int ArmPoly64PmullProbe() => Armi.Aes.IsSupported ? 1 : 0;

    private static string ArmSimdLevel()
    {
        if (!Armi.AdvSimd.IsSupported)
            return "scalar";
        if (Armi.Sve2.IsSupported)
            return "sve2";
        if (Armi.Sve.IsSupported)
            return "sve";
        return "neon";
    }

    private static void PrintArm32()
    {
        Console.WriteLine("ARCH=arm32");

        Console.WriteLine($"NEON={(Armi.AdvSimd.IsSupported ? 1 : 0)}");
        Console.WriteLine("SVE=0");
        Console.WriteLine("SVE2=0");

        Console.WriteLine($"AES={(Armi.Aes.IsSupported ? 1 : 0)}");
        Console.WriteLine($"SHA1={(Armi.Sha1.IsSupported ? 1 : 0)}");
        Console.WriteLine($"SHA256={(Armi.Sha256.IsSupported ? 1 : 0)}");
        Console.WriteLine($"SHA512={GetIntrinsicTriState("System.Runtime.Intrinsics.Arm.Sha512")}");
        Console.WriteLine($"SHA3={GetIntrinsicTriState("System.Runtime.Intrinsics.Arm.Sha3")}");

        Console.WriteLine($"CRC32={(Armi.Crc32.IsSupported ? 1 : 0)}");
        Console.WriteLine($"PMULL={ArmPoly64PmullProbe()}");

        Console.WriteLine($"SIMDLVL={ArmSimdLevel32()}");
    }

    private static string ArmSimdLevel32()
    {
        if (!Armi.AdvSimd.IsSupported)
            return "scalar";
        return "neon";
    }
}
