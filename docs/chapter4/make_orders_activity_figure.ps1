Add-Type -AssemblyName System.Drawing

$folder = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $folder 'orders-activity-original.png'
$pngDestination = Join-Path $folder 'figure-4.8-orders-activity.png'
$svgDestination = Join-Path $folder 'figure-4.8-orders-activity.svg'
$caption = 'Figure 4.8. Admin Orders & activity interface'
$callouts = @(
    @{ N = '1'; X = 65; Y = 220; StartX = 93; TargetX = 190; TargetY = 220 },
    @{ N = '2'; X = 1100; Y = 245; StartX = 1072; TargetX = 750; TargetY = 275 },
    @{ N = '3'; X = 980; Y = 300; StartX = 980; TargetX = 980; TargetY = 335 },
    @{ N = '4'; X = 2115; Y = 355; StartX = 2087; TargetX = 2004; TargetY = 355 },
    @{ N = '5'; X = 2115; Y = 425; StartX = 2087; TargetX = 2004; TargetY = 425 },
    @{ N = '6'; X = 2115; Y = 510; StartX = 2087; TargetX = 1795; TargetY = 510 },
    @{ N = '7'; X = 2115; Y = 655; StartX = 2087; TargetX = 1980; TargetY = 655 }
)

$image = [System.Drawing.Image]::FromFile($source)
$canvas = [System.Drawing.Bitmap]::new(2180, 1047)
$graphics = [System.Drawing.Graphics]::FromImage($canvas)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$graphics.Clear([System.Drawing.Color]::White)
$ink = [System.Drawing.Color]::FromArgb(29, 29, 29)
$pen = [System.Drawing.Pen]::new($ink, 3)
$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.EndCap = [System.Drawing.Drawing2D.LineCap]::ArrowAnchor
$border = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(181, 181, 181), 2)
$brush = [System.Drawing.SolidBrush]::new($ink)
$white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
$numberFont = [System.Drawing.Font]::new('Arial', 18, [System.Drawing.FontStyle]::Bold)
$captionFont = [System.Drawing.Font]::new('Arial', 20, [System.Drawing.FontStyle]::Regular)
$center = [System.Drawing.StringFormat]::new()
$center.Alignment = [System.Drawing.StringAlignment]::Center
$center.LineAlignment = [System.Drawing.StringAlignment]::Center

try {
    $graphics.DrawRectangle($border, 130, 38, $image.Width + 4, $image.Height + 4)
    $graphics.DrawImage($image, 132, 40, $image.Width, $image.Height)
    foreach ($item in $callouts) {
        $graphics.DrawLine($pen, $item.StartX, $item.Y, $item.TargetX, $item.TargetY)
        $graphics.FillEllipse($white, $item.X - 25, $item.Y - 25, 50, 50)
        $graphics.DrawEllipse($pen, $item.X - 25, $item.Y - 25, 50, 50)
        $graphics.DrawString($item.N, $numberFont, $brush,
            [System.Drawing.RectangleF]::new($item.X - 25, $item.Y - 25, 50, 50), $center)
    }
    $graphics.DrawString($caption, $captionFont, $brush,
        [System.Drawing.RectangleF]::new(290, 979, 1600, 42), $center)
    $canvas.Save($pngDestination, [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
    $center.Dispose(); $captionFont.Dispose(); $numberFont.Dispose()
    $white.Dispose(); $brush.Dispose(); $border.Dispose(); $pen.Dispose()
    $graphics.Dispose(); $canvas.Dispose(); $image.Dispose()
}

$encoded = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($source))
$svgCallouts = foreach ($item in $callouts) {
    '<line x1="{0}" y1="{1}" x2="{2}" y2="{3}" marker-end="url(#arrow)"/>' -f $item.StartX, $item.Y, $item.TargetX, $item.TargetY
    '<circle cx="{0}" cy="{1}" r="25" fill="#fff" stroke="#1d1d1d" stroke-width="3"/>' -f $item.X, $item.Y
    '<text x="{0}" y="{1}" fill="#1d1d1d" font-family="Arial, Helvetica, sans-serif" font-size="25" font-weight="bold" text-anchor="middle" dominant-baseline="middle">{2}</text>' -f $item.X, ($item.Y + 1), $item.N
}
$svg = @"
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="2180" height="1047" viewBox="0 0 2180 1047" role="img" aria-label="$caption with numbered callouts">
  <defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#1d1d1d"/></marker></defs>
  <rect width="2180" height="1047" fill="#fff"/>
  <rect x="130" y="38" width="1921" height="911" fill="#fff" stroke="#b5b5b5" stroke-width="2"/>
  <image x="132" y="40" width="1917" height="907" xlink:href="data:image/png;base64,$encoded"/>
  <g fill="none" stroke="#1d1d1d" stroke-width="3" stroke-linecap="round">$($svgCallouts -join '')</g>
  <text x="1090" y="1009" fill="#222" font-family="Arial, Helvetica, sans-serif" font-size="27" text-anchor="middle">Figure 4.8. Admin Orders &amp; activity interface</text>
</svg>
"@
[System.IO.File]::WriteAllText($svgDestination, $svg, [System.Text.UTF8Encoding]::new($false))
