Add-Type -AssemblyName System.Drawing

$folder = Split-Path -Parent $MyInvocation.MyCommand.Path
$figures = @(
    @{
        Source = 'admin-overview-upper-original.png'
        Stem = 'figure-4.7a-admin-overview-upper'
        Caption = 'Figure 4.7(a). Admin Overview: upper section'
        Callouts = @(
            @{ N = '1'; X = 65; Y = 190; StartX = 93; TargetX = 260; TargetY = 190 },
            @{ N = '2'; X = 850; Y = 80; StartX = 822; TargetX = 745; TargetY = 80 },
            @{ N = '3'; X = 1430; Y = 206; StartX = 1410; TargetX = 1280; TargetY = 290 },
            @{ N = '4'; X = 1000; Y = 557; StartX = 990; TargetX = 940; TargetY = 595 },
            @{ N = '5'; X = 2115; Y = 70; StartX = 2087; TargetX = 1980; TargetY = 70 },
            @{ N = '6'; X = 2115; Y = 365; StartX = 2087; TargetX = 1980; TargetY = 365 },
            @{ N = '7'; X = 2115; Y = 580; StartX = 2087; TargetX = 1980; TargetY = 580 }
        )
    },
    @{
        Source = 'admin-overview-lower-original.png'
        Stem = 'figure-4.7b-admin-overview-lower'
        Caption = 'Figure 4.7(b). Admin Overview: lower section'
        Callouts = @(
            @{ N = '8'; X = 660; Y = 115; StartX = 660; TargetX = 660; TargetY = 165 },
            @{ N = '9'; X = 1000; Y = 115; StartX = 1000; TargetX = 1000; TargetY = 165 },
            @{ N = '10'; X = 1360; Y = 115; StartX = 1360; TargetX = 1360; TargetY = 165 },
            @{ N = '11'; X = 1545; Y = 815; StartX = 1517; TargetX = 1455; TargetY = 815 }
        )
    }
)

foreach ($figure in $figures) {
    $source = Join-Path $folder $figure.Source
    $pngDestination = Join-Path $folder ($figure.Stem + '.png')
    $svgDestination = Join-Path $folder ($figure.Stem + '.svg')
    $image = [System.Drawing.Image]::FromFile($source)
    $canvas = [System.Drawing.Bitmap]::new(2180, 1055)
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
        $graphics.DrawRectangle($border, 130, 38, $image.Width + 4, 919)
        $graphics.DrawImage($image, 132, 40, $image.Width, 915)
        foreach ($item in $figure.Callouts) {
            $graphics.DrawLine($pen, $item.StartX, $item.Y, $item.TargetX, $item.TargetY)
            $graphics.FillEllipse($white, $item.X - 25, $item.Y - 25, 50, 50)
            $graphics.DrawEllipse($pen, $item.X - 25, $item.Y - 25, 50, 50)
            $graphics.DrawString($item.N, $numberFont, $brush,
                [System.Drawing.RectangleF]::new($item.X - 25, $item.Y - 25, 50, 50), $center)
        }
        $graphics.DrawString($figure.Caption, $captionFont, $brush,
            [System.Drawing.RectangleF]::new(290, 987, 1600, 42), $center)
        $canvas.Save($pngDestination, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $center.Dispose(); $captionFont.Dispose(); $numberFont.Dispose()
        $white.Dispose(); $brush.Dispose(); $border.Dispose(); $pen.Dispose()
        $graphics.Dispose(); $canvas.Dispose(); $image.Dispose()
    }

    $encoded = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($source))
    $svgCallouts = foreach ($item in $figure.Callouts) {
        '<line x1="{0}" y1="{1}" x2="{2}" y2="{3}" marker-end="url(#arrow)"/>' -f $item.StartX, $item.Y, $item.TargetX, $item.TargetY
        '<circle cx="{0}" cy="{1}" r="25" fill="#fff" stroke="#1d1d1d" stroke-width="3"/>' -f $item.X, $item.Y
        '<text x="{0}" y="{1}" fill="#1d1d1d" font-family="Arial, Helvetica, sans-serif" font-size="25" font-weight="bold" text-anchor="middle" dominant-baseline="middle">{2}</text>' -f $item.X, ($item.Y + 1), $item.N
    }
    $svg = @"
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="2180" height="1055" viewBox="0 0 2180 1055" role="img" aria-label="$($figure.Caption) with numbered callouts">
  <defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#1d1d1d"/></marker></defs>
  <rect width="2180" height="1055" fill="#fff"/>
  <rect x="130" y="38" width="$($figure.Source -eq 'admin-overview-upper-original.png' ? 1920 : 1921)" height="919" fill="#fff" stroke="#b5b5b5" stroke-width="2"/>
  <image x="132" y="40" width="$($figure.Source -eq 'admin-overview-upper-original.png' ? 1916 : 1917)" height="915" xlink:href="data:image/png;base64,$encoded"/>
  <g fill="none" stroke="#1d1d1d" stroke-width="3" stroke-linecap="round">$($svgCallouts -join '')</g>
  <text x="1090" y="1017" fill="#222" font-family="Arial, Helvetica, sans-serif" font-size="27" text-anchor="middle">$($figure.Caption)</text>
</svg>
"@
    [System.IO.File]::WriteAllText($svgDestination, $svg, [System.Text.UTF8Encoding]::new($false))
}
