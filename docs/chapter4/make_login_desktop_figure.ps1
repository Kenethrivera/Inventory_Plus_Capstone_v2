Add-Type -AssemblyName System.Drawing

$folder = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $folder 'inventory-plus-login-desktop-original.jpg'
$pngDestination = Join-Path $folder 'figure-4.6-login-interface.png'
$svgDestination = Join-Path $folder 'figure-4.6-login-interface.svg'

$callouts = @(
    @{ Number = '1'; CircleX = 80; CircleY = 100; StartX = 103; TargetX = 215; TargetY = 100 },
    @{ Number = '2'; CircleX = 80; CircleY = 470; StartX = 103; TargetX = 270; TargetY = 470 },
    @{ Number = '3'; CircleX = 1680; CircleY = 445; StartX = 1657; TargetX = 1430; TargetY = 445 },
    @{ Number = '4'; CircleX = 1680; CircleY = 500; StartX = 1657; TargetX = 1428; TargetY = 500 },
    @{ Number = '5'; CircleX = 1680; CircleY = 545; StartX = 1657; TargetX = 1428; TargetY = 545 },
    @{ Number = '6'; CircleX = 1680; CircleY = 610; StartX = 1657; TargetX = 1430; TargetY = 610 },
    @{ Number = '7'; CircleX = 1680; CircleY = 670; StartX = 1657; TargetX = 1340; TargetY = 670 }
)

$canvas = [System.Drawing.Bitmap]::new(1760, 1035)
$image = [System.Drawing.Image]::FromFile($source)
$graphics = [System.Drawing.Graphics]::FromImage($canvas)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$graphics.Clear([System.Drawing.Color]::White)

$ink = [System.Drawing.Color]::FromArgb(29, 29, 29)
$pen = [System.Drawing.Pen]::new($ink, 2.5)
$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.EndCap = [System.Drawing.Drawing2D.LineCap]::ArrowAnchor
$border = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(181, 181, 181), 2)
$brush = [System.Drawing.SolidBrush]::new($ink)
$white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
$numberFont = [System.Drawing.Font]::new('Arial', 14, [System.Drawing.FontStyle]::Bold)
$captionFont = [System.Drawing.Font]::new('Arial', 17, [System.Drawing.FontStyle]::Regular)
$center = [System.Drawing.StringFormat]::new()
$center.Alignment = [System.Drawing.StringAlignment]::Center
$center.LineAlignment = [System.Drawing.StringAlignment]::Center

try {
    $graphics.DrawRectangle($border, 158, 43, 1444, 904)
    $graphics.DrawImage($image, 160, 45, 1440, 900)
    foreach ($item in $callouts) {
        $graphics.DrawLine($pen, $item.StartX, $item.CircleY, $item.TargetX, $item.TargetY)
        $graphics.FillEllipse($white, $item.CircleX - 19, $item.CircleY - 19, 38, 38)
        $graphics.DrawEllipse($pen, $item.CircleX - 19, $item.CircleY - 19, 38, 38)
        $graphics.DrawString($item.Number, $numberFont, $brush,
            [System.Drawing.RectangleF]::new($item.CircleX - 19, $item.CircleY - 19, 38, 38), $center)
    }
    $graphics.DrawString('Figure 4.6. Inventory Plus desktop login interface', $captionFont, $brush,
        [System.Drawing.RectangleF]::new(260, 971, 1240, 42), $center)
    $canvas.Save($pngDestination, [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
    $center.Dispose(); $captionFont.Dispose(); $numberFont.Dispose()
    $white.Dispose(); $brush.Dispose(); $border.Dispose(); $pen.Dispose()
    $graphics.Dispose(); $image.Dispose(); $canvas.Dispose()
}

$encoded = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($source))
$svgCallouts = foreach ($item in $callouts) {
    '<line x1="{0}" y1="{1}" x2="{2}" y2="{3}" marker-end="url(#arrow)"/>' -f $item.StartX, $item.CircleY, $item.TargetX, $item.TargetY
    '<circle cx="{0}" cy="{1}" r="19" fill="#fff" stroke="#1d1d1d" stroke-width="2.5"/>' -f $item.CircleX, $item.CircleY
    '<text x="{0}" y="{1}" fill="#1d1d1d" font-family="Arial, Helvetica, sans-serif" font-size="21" font-weight="bold" text-anchor="middle" dominant-baseline="middle">{2}</text>' -f $item.CircleX, ($item.CircleY + 1), $item.Number
}
$svg = @"
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1760" height="1035" viewBox="0 0 1760 1035" role="img" aria-label="Figure 4.6. Inventory Plus desktop login interface with seven numbered callouts">
  <defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#1d1d1d"/></marker></defs>
  <rect width="1760" height="1035" fill="#fff"/>
  <rect x="158" y="43" width="1444" height="904" fill="#fff" stroke="#b5b5b5" stroke-width="2"/>
  <image x="160" y="45" width="1440" height="900" xlink:href="data:image/jpeg;base64,$encoded"/>
  <g fill="none" stroke="#1d1d1d" stroke-width="2.5" stroke-linecap="round">$($svgCallouts -join '')</g>
  <text x="880" y="1000" fill="#222" font-family="Arial, Helvetica, sans-serif" font-size="23" text-anchor="middle">Figure 4.6. Inventory Plus desktop login interface</text>
</svg>
"@
[System.IO.File]::WriteAllText($svgDestination, $svg, [System.Text.UTF8Encoding]::new($false))
