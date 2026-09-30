using Avalonia;
using Avalonia.Media.Imaging;
using DraftZero.App.Services;

namespace DraftZero.App.Platform;

/// <summary>
/// Mac 开发构建的占位渲染器：不出真页图，返回页数错误说明。
/// （PDF 提取走 PdfPig 跨平台；Windows 发布构建用 WindowsPdfPageRenderer，
/// 实机预览效果在 P-012/P-013 复核——见计划 P-010。）
/// </summary>
public sealed class StubPdfPageRenderer : IPdfPageRenderer
{
    public Task<PdfPageResult> RenderPageAsync(string pdfPath, int pageNumber, double targetWidthPx) =>
        Task.FromResult(PdfPageResult.Failed(
            "当前开发环境不含 Windows PDF 渲染器；预览以 Windows 实机为准。", pageNumber, 0));

    public Task<(int PageCount, string? Error)> GetPageCountAsync(string pdfPath)
    {
        try
        {
            // PdfPig 读取页数（跨平台可用）
            using var document = UglyToad.PdfPig.PdfDocument.Open(pdfPath);
            return Task.FromResult<(int, string?)>((document.NumberOfPages, null));
        }
        catch (Exception ex)
        {
            return Task.FromResult<(int, string?)>((0, $"无法读取 PDF：{ex.Message}"));
        }
    }
}
