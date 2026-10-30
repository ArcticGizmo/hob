using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using Svg;

// Renders the vector straight to every frame size instead of scaling one large bitmap down, which is what keeps
// the small frames sharp. Adapted from flamingle's IconGen.

string root = FindRepoRoot(AppContext.BaseDirectory);
string svgPath = Path.Combine(root, "hob.svg");
string icoPath = Path.Combine(root, "src", "Hob.Cli", "hob.ico");

var doc = SvgDocument.Open(svgPath);
// Inkscape sets width and height in mm, so Svg.NET applies a viewBox-to-viewport scale that throws off Bounds.
// Pinning them to the viewBox makes that transform identity, so the crop lines up with user coordinates.
if (doc.ViewBox.Width > 0 && doc.ViewBox.Height > 0)
{
    doc.Width = new SvgUnit(SvgUnitType.User, doc.ViewBox.Width);
    doc.Height = new SvgUnit(SvgUnitType.User, doc.ViewBox.Height);
}

// Crop to the drawn content so the artwork fills each frame rather than inheriting the viewBox's margin; the pad
// stops anti-aliased edges clipping.
const float Pad = 0.02f;
var box = doc.Bounds;
float side = Math.Max(box.Width, box.Height) * (1 + Pad * 2);
var origin = new PointF(box.X + box.Width / 2 - side / 2, box.Y + box.Height / 2 - side / 2);

// A real frame at each size Windows asks for across DPI scales (title bars, Start, Settings > Apps), so it never
// resamples at runtime.
int[] sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];
WriteIco(icoPath, sizes.Select(size => RenderPng(size)).ToArray(), sizes);
Console.WriteLine($"{icoPath} [{string.Join(", ", sizes)}]");
return 0;

byte[] RenderPng(int size)
{
    using var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
    bmp.SetResolution(96, 96);
    using (var g = Graphics.FromImage(bmp))
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.Clear(Color.Transparent);
        g.ScaleTransform(size / side, size / side);
        g.TranslateTransform(-origin.X, -origin.Y);
        doc.Draw(g);
    }
    using var ms = new MemoryStream();
    bmp.Save(ms, ImageFormat.Png);
    return ms.ToArray();
}

// PNG-compressed frames (Vista and later) keep the file small and allow the 256 px frame.
static void WriteIco(string path, byte[][] frames, int[] sizes)
{
    using var w = new BinaryWriter(File.Create(path));
    w.Write((ushort)0);
    w.Write((ushort)1);
    w.Write((ushort)frames.Length);

    int offset = 6 + frames.Length * 16;
    for (int i = 0; i < frames.Length; i++)
    {
        byte dimension = (byte)(sizes[i] >= 256 ? 0 : sizes[i]);
        w.Write(dimension);
        w.Write(dimension);
        w.Write((byte)0);
        w.Write((byte)0);
        w.Write((ushort)1);
        w.Write((ushort)32);
        w.Write(frames[i].Length);
        w.Write(offset);
        offset += frames[i].Length;
    }
    foreach (var frame in frames) w.Write(frame);
}

static string FindRepoRoot(string start)
{
    for (var dir = new DirectoryInfo(start); dir != null; dir = dir.Parent)
    {
        if (File.Exists(Path.Combine(dir.FullName, "hob.svg"))) return dir.FullName;
    }
    throw new FileNotFoundException("hob.svg not found above " + start);
}
