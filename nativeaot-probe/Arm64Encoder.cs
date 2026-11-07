using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;

public static unsafe class NxNativeArm64Encoder
{
    private static int Register(int value, string name)
    {
        if ((uint)value > 31) throw new ArgumentOutOfRangeException(name, "AArch64 register must be x0-x31.");
        return value;
    }

    private static int GeneralRegister(int value, string name)
    {
        if ((uint)value > 30) throw new ArgumentOutOfRangeException(name, "This instruction requires x0-x30; register 31 is not valid here.");
        return value;
    }

    private static int ScaledSigned(int value, int scale, int minUnits, int maxUnits, string name)
    {
        if (value % scale != 0) throw new ArgumentOutOfRangeException(name, $"Offset must be a multiple of {scale}.");
        int units = value / scale;
        if (units < minUnits || units > maxUnits) throw new ArgumentOutOfRangeException(name, "Offset is outside the instruction's signed immediate range.");
        return units;
    }

    public static uint B(long from, long to)
    {
        long off = checked(to - from);
        if ((off & 3) != 0 || off < -(1L << 27) || off >= (1L << 27)) throw new ArgumentOutOfRangeException(nameof(to), "B target must be 4-byte aligned and within ±128 MiB.");
        return 0x14000000u | ((uint)(off >> 2) & 0x03FFFFFFu);
    }

    public static uint BL(long from, long to)
    {
        long off = checked(to - from);
        if ((off & 3) != 0 || off < -(1L << 27) || off >= (1L << 27)) throw new ArgumentOutOfRangeException(nameof(to), "BL target must be 4-byte aligned and within ±128 MiB.");
        return 0x94000000u | ((uint)(off >> 2) & 0x03FFFFFFu);
    }

    public static uint STP(int t, int t2, int n, int off)
    {
        int imm = ScaledSigned(off, 8, -64, 63, nameof(off));
        return 0xA9000000u | (((uint)imm & 0x7Fu) << 15) | ((uint)Register(t2, nameof(t2)) << 10) | ((uint)Register(n, nameof(n)) << 5) | (uint)Register(t, nameof(t));
    }

    public static uint LDP(int t, int t2, int n, int off)
    {
        int imm = ScaledSigned(off, 8, -64, 63, nameof(off));
        return 0xA9400000u | (((uint)imm & 0x7Fu) << 15) | ((uint)Register(t2, nameof(t2)) << 10) | ((uint)Register(n, nameof(n)) << 5) | (uint)Register(t, nameof(t));
    }

    public static uint STP_PRE(int t, int t2, int n, int off)
    {
        int imm = ScaledSigned(off, 8, -64, 63, nameof(off));
        return 0xA9800000u | (((uint)imm & 0x7Fu) << 15) | ((uint)Register(t2, nameof(t2)) << 10) | ((uint)Register(n, nameof(n)) << 5) | (uint)Register(t, nameof(t));
    }

    public static uint LDP_POST(int t, int t2, int n, int off)
    {
        int imm = ScaledSigned(off, 8, -64, 63, nameof(off));
        return 0xA8C00000u | (((uint)imm & 0x7Fu) << 15) | ((uint)Register(t2, nameof(t2)) << 10) | ((uint)Register(n, nameof(n)) << 5) | (uint)Register(t, nameof(t));
    }

    public static uint STUR(int t, int n, int off)
    {
        if (off < -256 || off > 255) throw new ArgumentOutOfRangeException(nameof(off), "STUR offset must fit signed 9 bits.");
        return 0xF8000000u | (((uint)off & 0x1FFu) << 12) | ((uint)Register(n, nameof(n)) << 5) | (uint)Register(t, nameof(t));
    }

    public static uint LDUR(int t, int n, int off)
    {
        if (off < -256 || off > 255) throw new ArgumentOutOfRangeException(nameof(off), "LDUR offset must fit signed 9 bits.");
        return 0xF8400000u | (((uint)off & 0x1FFu) << 12) | ((uint)Register(n, nameof(n)) << 5) | (uint)Register(t, nameof(t));
    }

    public static uint LDRX(int t, int n, int imm12 = 0)
    {
        if ((uint)imm12 > 4095) throw new ArgumentOutOfRangeException(nameof(imm12), "LDR X immediate must be 0-4095 scaled units.");
        return 0xF9400000u | ((uint)imm12 << 10) | ((uint)Register(n, nameof(n)) << 5) | (uint)Register(t, nameof(t));
    }

    public static uint STRX(int t, int n, int imm12 = 0)
    {
        if ((uint)imm12 > 4095) throw new ArgumentOutOfRangeException(nameof(imm12), "STR X immediate must be 0-4095 scaled units.");
        return 0xF9000000u | ((uint)imm12 << 10) | ((uint)Register(n, nameof(n)) << 5) | (uint)Register(t, nameof(t));
    }

    public static uint MRS_TPIDRRO(int t) => 0xD53BD060u | (uint)Register(t, nameof(t));

    public static uint ADRP(int dd, long pc, long target)
    {
        long pages = ((target & ~0xFFFL) - (pc & ~0xFFFL)) >> 12;
        if (pages < -(1L << 20) || pages >= (1L << 20)) throw new ArgumentOutOfRangeException(nameof(target), "ADRP target must be within ±4 GiB of the PC page.");
        uint imm = (uint)pages & 0x1FFFFFu;
        return 0x90000000u | ((imm & 3u) << 29) | (((imm >> 2) & 0x7FFFFu) << 5) | (uint)Register(dd, nameof(dd));
    }

    public static uint ADDI(int dd, int n, int imm12, int sh = 0)
    {
        if ((uint)imm12 > 4095 || (sh != 0 && sh != 1)) throw new ArgumentOutOfRangeException(nameof(imm12), "ADDI immediate must be 0-4095 with shift 0 or 1.");
        return 0x91000000u | ((uint)sh << 22) | ((uint)imm12 << 10) | ((uint)Register(n, nameof(n)) << 5) | (uint)Register(dd, nameof(dd));
    }

    public static uint ADDR(int dd, int n, int m) =>
        0x8B000000u | ((uint)Register(m, nameof(m)) << 16) | ((uint)Register(n, nameof(n)) << 5) | (uint)Register(dd, nameof(dd));

    public static uint SUBI(int dd, int n, int imm12, int sh = 0)
    {
        if ((uint)imm12 > 4095 || (sh != 0 && sh != 1)) throw new ArgumentOutOfRangeException(nameof(imm12), "SUBI immediate must be 0-4095 with shift 0 or 1.");
        return 0xD1000000u | ((uint)sh << 22) | ((uint)imm12 << 10) | ((uint)Register(n, nameof(n)) << 5) | (uint)Register(dd, nameof(dd));
    }

    public static uint BR(int n) => 0xD61F0000u | ((uint)GeneralRegister(n, nameof(n)) << 5);
    public static uint CMPR(int n, int m) => 0xEB00001Fu | ((uint)Register(m, nameof(m)) << 16) | ((uint)Register(n, nameof(n)) << 5);

    public static uint BEQ(long from, long to)
    {
        long off = checked(to - from);
        if ((off & 3) != 0 || off < -(1L << 20) || off >= (1L << 20)) throw new ArgumentOutOfRangeException(nameof(to), "BEQ target must be 4-byte aligned and within ±1 MiB.");
        return 0x54000000u | (((uint)(off >> 2) & 0x7FFFFu) << 5);
    }

    public static uint BRK(int imm)
    {
        if ((uint)imm > 0xFFFF) throw new ArgumentOutOfRangeException(nameof(imm), "BRK immediate must fit 16 bits.");
        return 0xD4200000u | ((uint)imm << 5);
    }

    public static uint BLR(int n) => 0xD63F0000u | ((uint)GeneralRegister(n, nameof(n)) << 5);
    public const uint NOP = 0xD503201F;

    [UnmanagedCallersOnly(EntryPoint = "nxn_arm64_encoder_selftest", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int SelfTest(byte* output, int capacity)
    {
        if (output == null || capacity <= 1) return -1;
        try
        {
            var tests = new (string Name, uint Actual, uint Expected)[]
            {
                ("B", B(0x1000, 0x1010), 0x14000004),
                ("BL", BL(0x1000, 0x1010), 0x94000004),
                ("STP_PRE", STP_PRE(29, 30, 31, -16), 0xA9BF7BFD),
                ("LDP_POST", LDP_POST(29, 30, 31, 16), 0xA8C17BFD),
                ("STUR", STUR(0, 1, -8), 0xF81F8020),
                ("LDUR", LDUR(0, 1, 8), 0xF8408020),
                ("LDRX", LDRX(0, 1, 1), 0xF9400420),
                ("STRX", STRX(2, 3, 2), 0xF9000862),
                ("MRS_TPIDRRO", MRS_TPIDRRO(0), 0xD53BD060),
                ("ADRP", ADRP(0, 0x1000, 0x2000), 0xB0000000),
                ("ADDI", ADDI(0, 0, 1), 0x91000400),
                ("ADDR", ADDR(0, 1, 2), 0x8B020020),
                ("SUBI", SUBI(0, 1, 1), 0xD1000420),
                ("BR", BR(30), 0xD61F03C0),
                ("CMPR", CMPR(1, 2), 0xEB02003F),
                ("BEQ", BEQ(0x1000, 0x1010), 0x54000080),
                ("BRK", BRK(0), 0xD4200000),
                ("BLR", BLR(30), 0xD63F03C0),
                ("NOP", NOP, 0xD503201F)
            };
            var report = new StringBuilder();
            int passed = 0;
            foreach (var test in tests)
            {
                bool ok = test.Actual == test.Expected;
                if (ok) passed++;
                report.Append(test.Name).Append('|').Append(test.Actual.ToString("x8")).Append('|')
                      .Append(test.Expected.ToString("x8")).Append('|').Append(ok ? "OK" : "FAIL").Append('\n');
            }
            report.Insert(0, $"summary|{passed}/{tests.Length} AArch64 encoder vectors passed.\n");
            byte[] bytes = Encoding.UTF8.GetBytes(report.ToString());
            if (bytes.Length + 1 > capacity) return -2;
            Marshal.Copy(bytes, 0, (IntPtr)output, bytes.Length);
            output[bytes.Length] = 0;
            return passed == tests.Length ? 0 : 1;
        }
        catch (Exception e)
        {
            byte[] bytes = Encoding.UTF8.GetBytes("error|" + e.Message.Replace("\r", " ").Replace("\n", " "));
            if (bytes.Length + 1 > capacity) return -2;
            Marshal.Copy(bytes, 0, (IntPtr)output, bytes.Length);
            output[bytes.Length] = 0;
            return -1;
        }
    }
}
