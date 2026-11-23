Add-Type -AssemblyName System.Drawing

$folder = Split-Path -Parent $MyInvocation.MyCommand.Path
$figures = @(
    @{
        Source = 'store-map-layout-full-original.png'
        Cropped = 'store-map-layout-cropped.png'
        Stem = 'figure-4.10a-store-map-layout'
        Caption = 'Figure 4.10(a). Store map: layout editing'
        Callouts = @(
            @{ N = '1'; X = 65; Y = 342; StartX = 93; TargetX = 175; TargetY = 342 },
            @{ N = '2'; X = 800; Y = 355; StartX = 800; TargetX = 800; TargetY = 305 },
            @{ N = '3'; X = 1050; Y = 420; StartX = 1050; TargetX = 1050; TargetY = 500 },
            @{ N = '4'; X = 2115; Y = 550; StartX = 2087; TargetX = 1995; TargetY = 550 },
            @{ N = '5'; X = 2115; Y = 190; StartX = 2087; TargetX = 1930; TargetY = 190 }
        )
    },
    @{
        Source = 'store-map-items-full-original.png'
        Cropped = 'store-map-items-cropped.png'
        Stem = 'figure-4.10b-store-map-items'
        Caption = 'Figure 4.10(b). Store map: item assignment'
        Callouts = @(
            @{ N = '6'; X = 1580; Y = 90; StartX = 1580; TargetX = 1630; TargetY = 145 },
            @{ N = '7'; X = 1050; Y = 340; StartX = 1050; TargetX = 1050; TargetY = 470 },
            @{ N = '8'; X = 2115; Y = 235; StartX = 2087; TargetX = 1970; TargetY = 235 },
            @{ N = '9'; X = 2115; Y = 355; StartX = 2087; TargetX = 1970; TargetY = 355 }
        )
    },
    @{
        Source = 'store-map-3d-full-original.png'
        Cropped = 'store-map-3d-cropped.png'
        Stem = 'figure-4.10c-store-map-3d'
        Caption = 'Figure 4.10(c). Store map: 3D view'
        Callouts = @(
            @{ N = '10'; X = 2115; Y = 145; StartX = 2087; TargetX = 1980; TargetY = 145 },
            @{ N = '11'; X = 1090; Y = 330; StartX = 1090; TargetX = 1090; TargetY = 490 },
            @{ N = '12'; X = 2115; Y = 325; StartX = 2087; TargetX = 1980; TargetY = 325 }
        )
    }
)

foreach ($figure in $figures) {
    $fullSource = Join-Path $folder $figure.Source
    $croppedSource = Join-Path $folder $figure.Cropped
    $pngDestination = Join-Path $folder ($figure.Stem + '.png')
    $svgDestination = Join-Path $folder ($figure.Stem + '.svg')

    # Crop the browser tabs and address bar above y=100 and the pixels below the system screen.
    $original = [System.Drawing.Image]::FromFile($fullSource)
    $cropped = [System.Drawing.Bitmap]::new(1910, 917)
    $cropGraphics = [System.Drawing.Graphics]::FromImage($cropped)
    try {
        $cropGraphics.DrawImage($original,
            [System.Drawing.Rectangle]::new(0, 0, 1910, 917),
            [System.Drawing.Rectangle]::new(5, 100, 1910, 917),
            [System.Drawing.GraphicsUnit]::Pixel)
        $cropped.Save($croppedSource, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $cropGraphics.Dispose(); $cropped.Dispose(); $original.Dispose()
    }

    $image = [System.Drawing.Image]::FromFile($croppedSource)
    $canvas = [System.Drawing.Bitmap]::new(2180, 1057)
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
        $graphics.DrawRectangle($border, 130, 38, 1914, 921)
        $graphics.DrawImage($image, 132, 40, 1910, 917)
        foreach ($item in $figure.Callouts) {
            $graphics.DrawLine($pen, $item.StartX, $item.Y, $item.TargetX, $item.TargetY)
            $graphics.FillEllipse($white, $item.X - 25, $item.Y - 25, 50, 50)
            $graphics.DrawEllipse($pen, $item.X - 25, $item.Y - 25, 50, 50)
            $graphics.DrawString($item.N, $numberFont, $brush,
                [System.Drawing.RectangleF]::new($item.X - 25, $item.Y - 25, 50, 50), $center)
        }
        $graphics.DrawString($figure.Caption, $captionFont, $brush,
            [System.Drawing.RectangleF]::new(290, 989, 1600, 42), $center)
        $canvas.Save($pngDestination, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $center.Dispose(); $captionFont.Dispose(); $numberFont.Dispose()
        $white.Dispose(); $brush.Dispose(); $border.Dispose(); $pen.Dispose()
        $graphics.Dispose(); $canvas.Dispose(); $image.Dispose()
    }

    $encoded = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($croppedSource))
    $svgCallouts = foreach ($item in $figure.Callouts) {
        '<line x1="{0}" y1="{1}" x2="{2}" y2="{3}" marker-end="url(#arrow)"/>' -f $item.StartX, $item.Y, $item.TargetX, $item.TargetY
        '<circle cx="{0}" cy="{1}" r="25" fill="#fff" stroke="#1d1d1d" stroke-width="3"/>' -f $item.X, $item.Y
        '<text x="{0}" y="{1}" fill="#1d1d1d" font-family="Arial, Helvetica, sans-serif" font-size="25" font-weight="bold" text-anchor="middle" dominant-baseline="middle">{2}</text>' -f $item.X, ($item.Y + 1), $item.N
    }
    $svg = @"
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="2180" height="1057" viewBox="0 0 2180 1057" role="img" aria-label="$($figure.Caption) with numbered callouts">
  <defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#1d1d1d"/></marker></defs>
  <rect width="2180" height="1057" fill="#fff"/>
  <rect x="130" y="38" width="1914" height="921" fill="#fff" stroke="#b5b5b5" stroke-width="2"/>
  <image x="132" y="40" width="1910" height="917" xlink:href="data:image/png;base64,$encoded"/>
  <g fill="none" stroke="#1d1d1d" stroke-width="3" stroke-linecap="round">$($svgCallouts -join '')</g>
  <text x="1090" y="1019" fill="#222" font-family="Arial, Helvetica, sans-serif" font-size="27" text-anchor="middle">$($figure.Caption)</text>
</svg>
"@
    [System.IO.File]::WriteAllText($svgDestination, $svg, [System.Text.UTF8Encoding]::new($false))
}
