using OpenCvSharp;
using System.Text;

namespace BeginnersTasks;

public partial class MainPage : ContentPage
{
    public MainPage()
    {
        InitializeComponent();
    }

    private void OnRunClicked(object sender, EventArgs e)
    {
        RunButton.IsEnabled = false;
        var sb = new StringBuilder();

        try
        {
            RunTests(sb);
            ResultLabel.TextColor = Colors.Green;
        }
        catch (Exception ex)
        {
            sb.AppendLine($"EXCEPTION: {ex}");
            ResultLabel.TextColor = Colors.Red;
        }
        finally
        {
            RunButton.IsEnabled = true;
        }

        ResultLabel.Text = sb.ToString();
    }

    private static void RunTests(StringBuilder sb)
    {
        // Test 1: Mat creation (core)
        using (var mat = new Mat(100, 100, MatType.CV_8UC3, Scalar.Red))
        {
            if (mat.Rows != 100 || mat.Cols != 100)
                throw new Exception($"Mat size wrong: {mat.Rows}x{mat.Cols}");
            sb.AppendLine($"PASS Mat creation: {mat.Rows}x{mat.Cols} {mat.Type()}");
        }

        // Test 2: CvtColor BGR->Gray (imgproc)
        using (var src = new Mat(50, 50, MatType.CV_8UC3, new Scalar(100, 150, 200)))
        using (var dst = new Mat())
        {
            Cv2.CvtColor(src, dst, ColorConversionCodes.BGR2GRAY);
            if (dst.Channels() != 1)
                throw new Exception($"CvtColor output has {dst.Channels()} channels, expected 1");
            sb.AppendLine($"PASS CvtColor: {dst.Rows}x{dst.Cols} channels={dst.Channels()}");
        }

        // Test 3: ImEncode PNG (imgcodecs)
        using (var mat = new Mat(32, 32, MatType.CV_8UC3, Scalar.Green))
        {
            Cv2.ImEncode(".png", mat, out var bytes);
            if (bytes == null || bytes.Length == 0)
                throw new Exception("ImEncode returned empty buffer");
            sb.AppendLine($"PASS ImEncode PNG: {bytes.Length} bytes");
        }

        // Test 4: ImEncode JPEG (imgcodecs)
        using (var mat = new Mat(64, 64, MatType.CV_8UC3, new Scalar(50, 100, 150)))
        {
            Cv2.ImEncode(".jpg", mat, out var bytes);
            if (bytes == null || bytes.Length == 0)
                throw new Exception("ImEncode JPEG returned empty buffer");
            sb.AppendLine($"PASS ImEncode JPEG: {bytes.Length} bytes");
        }

        sb.AppendLine();
        sb.AppendLine("All tests passed!");
    }
}