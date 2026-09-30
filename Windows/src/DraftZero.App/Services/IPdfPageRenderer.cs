using Avalonia;
using Avalonia.Media.Imaging;

namespace DraftZero.App.Services;

/// <summary>PDF 页渲染结果。</summary>
public sealed record PdfPageResult(Bitmap? Image, string? Error, int PageNumber, int PageCount)
{
    public static PdfPageResult Failed(string error, int pageNumber, int pageCount) =>
        new(null, error, pageNumber, pageCount);
}

/// <summary>
/// PDF 应用内页预览抽象（W-003：不得降为"只能打开系统外部阅读器"）。
/// Windows 发布构建用 Windows.Data.Pdf 渲染（无第三方许可负担）；
/// Mac 开发构建为占位渲染（真实预览在 Windows 实机复核）。
/// </summary>
public interface IPdfPageRenderer
{
    /// <summary>渲染指定页（1 基）到位图；失败返回 Error 文案。</summary>
    Task<PdfPageResult> RenderPageAsync(string pdfPath, int pageNumber, double targetWidthPx);

    Task<(int PageCount, string? Error)> GetPageCountAsync(string pdfPath);
}
