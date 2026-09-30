using Avalonia;
using Avalonia.Media.Imaging;
using DraftZero.App.Services;
using Windows.Data.Pdf;
using Windows.Storage;
using Windows.Storage.Streams;

namespace DraftZero.App.Platform;

/// <summary>
/// Windows.Data.Pdf 渲染到 Avalonia 位图（计划 §2 首选路径，系统组件无许可负担）。
/// 渲染在后台线程进行（WinRT API 自带线程封送）。
/// </summary>
public sealed class WindowsPdfPageRenderer : IPdfPageRenderer
{
    public async Task<PdfPageResult> RenderPageAsync(string pdfPath, int pageNumber, double targetWidthPx)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(pdfPath);
            var document = await PdfDocument.LoadFromFileAsync(file);
            if (pageNumber < 1 || pageNumber > (int)document.PageCount)
            {
                return PdfPageResult.Failed($"页码超出范围（1–{document.PageCount}）", pageNumber, (int)document.PageCount);
            }
            var page = document.GetPage((uint)(pageNumber - 1));
            try
            {
                var width = Math.Max(300, (int)targetWidthPx);
                var height = (int)(width * page.Size.Height / page.Size.Width);
                using var stream = new InMemoryRandomAccessStream();
                var options = new PdfPageRenderOptions
                {
                    DestinationWidth = (uint)width,
                    IsIgnoringHighContrast = false,
                };
                await page.RenderToStreamAsync(stream, options);
                var size = (int)stream.Size;
                var bytes = new byte[size];
                using var reader = new DataReader(stream.GetInputStreamAt(0));
                await reader.LoadAsync((uint)size);
                reader.ReadBytes(bytes);

                var bitmap = new Bitmap(new MemoryStream(bytes));
                return new PdfPageResult(bitmap, null, pageNumber, (int)document.PageCount);
            }
            finally
            {
                page.Dispose();
            }
        }
        catch (Exception ex)
        {
            return PdfPageResult.Failed($"PDF 渲染失败：{ex.Message}", pageNumber, 0);
        }
    }

    public async Task<(int PageCount, string? Error)> GetPageCountAsync(string pdfPath)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(pdfPath);
            var document = await PdfDocument.LoadFromFileAsync(file);
            return ((int)document.PageCount, null);
        }
        catch (Exception ex)
        {
            return (0, $"无法读取 PDF：{ex.Message}");
        }
    }
}
