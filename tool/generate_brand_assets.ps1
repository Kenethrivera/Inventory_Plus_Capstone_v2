# Regenerate Inventory Plus launcher icons and static launch images.
# Run from any directory: powershell -File tool/generate_brand_assets.ps1
Add-Type -AssemblyName System.Drawing

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$orange = [System.Drawing.Color]::FromArgb(200, 61, 8)
$white = [System.Drawing.Color]::White

function New-LogoMaster([bool] $rounded, [single] $markScale = 1) {
  $bitmap = [System.Drawing.Bitmap]::new(
    1024, 1024, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
  )
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.Clear([System.Drawing.Color]::Transparent)

  if ($rounded) {
    $shape = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $shape.AddArc(32, 32, 384, 384, 180, 90)
    $shape.AddArc(608, 32, 384, 384, 270, 90)
    $shape.AddArc(608, 608, 384, 384, 0, 90)
    $shape.AddArc(32, 608, 384, 384, 90, 90)
    $shape.CloseFigure()
    $brush = [System.Drawing.SolidBrush]::new($orange)
    $graphics.FillPath($brush, $shape)
    $brush.Dispose()
    $shape.Dispose()
  } else {
    $graphics.Clear($orange)
  }

  if ($markScale -ne 1) {
    $graphics.TranslateTransform(512, 512)
    $graphics.ScaleTransform($markScale, $markScale)
    $graphics.TranslateTransform(-512, -512)
  }

  $pen = [System.Drawing.Pen]::new($white, 58)
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  $top = [System.Drawing.PointF[]]@(
    [System.Drawing.PointF]::new(512, 252),
    [System.Drawing.PointF]::new(760, 380),
    [System.Drawing.PointF]::new(512, 512),
    [System.Drawing.PointF]::new(264, 380)
  )
  $graphics.DrawPolygon($pen, $top)
  $graphics.DrawLine($pen, 264, 380, 264, 660)
  $graphics.DrawLine($pen, 264, 660, 512, 796)
  $graphics.DrawLine($pen, 512, 796, 760, 660)
  $graphics.DrawLine($pen, 760, 660, 760, 380)
  $graphics.DrawLine($pen, 512, 512, 512, 796)
  $graphics.DrawLine($pen, 264, 855, 760, 855)
  $pen.Dispose()
  $graphics.Dispose()
  return $bitmap
}

$fullMaster = New-LogoMaster $false
$roundedMaster = New-LogoMaster $true
$maskableMaster = New-LogoMaster $false 0.58

function Get-LogoPng([int] $size, [bool] $rounded, [bool] $maskable = $false) {
  $source = if ($maskable) { $maskableMaster } elseif ($rounded) { $roundedMaster } else { $fullMaster }
  $bitmap = [System.Drawing.Bitmap]::new(
    $size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
  )
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
  $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $graphics.DrawImage($source, 0, 0, $size, $size)
  $graphics.Dispose()
  $stream = [System.IO.MemoryStream]::new()
  $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
  $bitmap.Dispose()
  $bytes = $stream.ToArray()
  $stream.Dispose()
  return ,$bytes
}

function Save-LogoPng([string] $relativePath, [int] $size, [bool] $rounded, [bool] $maskable = $false) {
  $path = Join-Path $projectRoot $relativePath
  [System.IO.File]::WriteAllBytes($path, (Get-LogoPng $size $rounded $maskable))
  Write-Output "$relativePath ($size x $size)"
}

$androidSizes = @{
  'mdpi' = 48
  'hdpi' = 72
  'xhdpi' = 96
  'xxhdpi' = 144
  'xxxhdpi' = 192
}
foreach ($density in $androidSizes.Keys) {
  Save-LogoPng "android/app/src/main/res/mipmap-$density/ic_launcher.png" $androidSizes[$density] $false
}

$iosCatalog = Get-Content (Join-Path $projectRoot 'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json') -Raw | ConvertFrom-Json
$iosSizes = @{}
foreach ($entry in $iosCatalog.images) {
  $pointSize = [double]($entry.size.Split('x')[0])
  $scale = [double]($entry.scale.TrimEnd('x'))
  $iosSizes[$entry.filename] = [int][Math]::Round($pointSize * $scale)
}
foreach ($filename in $iosSizes.Keys) {
  Save-LogoPng "ios/Runner/Assets.xcassets/AppIcon.appiconset/$filename" $iosSizes[$filename] $false
}

foreach ($size in @(64, 128, 192)) {
  $filename = if ($size -eq 64) { 'LaunchImage.png' } else { "LaunchImage@$(($size / 64))x.png" }
  Save-LogoPng "ios/Runner/Assets.xcassets/LaunchImage.imageset/$filename" $size $true
}

foreach ($size in @(16, 32, 64, 128, 256, 512, 1024)) {
  Save-LogoPng "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png" $size $true
}

Save-LogoPng 'web/icons/Icon-192.png' 192 $false
Save-LogoPng 'web/icons/Icon-512.png' 512 $false
Save-LogoPng 'web/icons/Icon-maskable-192.png' 192 $false $true
Save-LogoPng 'web/icons/Icon-maskable-512.png' 512 $false $true
Save-LogoPng 'web/favicon.png' 32 $true

$iconSizes = @(16, 32, 48, 64, 128, 256)
$images = @($iconSizes | ForEach-Object { Get-LogoPng $_ $true })
$iconPath = Join-Path $projectRoot 'windows/runner/resources/app_icon.ico'
$stream = [System.IO.File]::Create($iconPath)
$writer = [System.IO.BinaryWriter]::new($stream)
$writer.Write([uint16]0)
$writer.Write([uint16]1)
$writer.Write([uint16]$iconSizes.Count)
$offset = 6 + 16 * $iconSizes.Count
for ($i = 0; $i -lt $iconSizes.Count; $i++) {
  $dimension = if ($iconSizes[$i] -eq 256) { 0 } else { $iconSizes[$i] }
  $writer.Write([byte]$dimension)
  $writer.Write([byte]$dimension)
  $writer.Write([byte]0)
  $writer.Write([byte]0)
  $writer.Write([uint16]1)
  $writer.Write([uint16]32)
  $writer.Write([uint32]$images[$i].Length)
  $writer.Write([uint32]$offset)
  $offset += $images[$i].Length
}
foreach ($bytes in $images) { $writer.Write([byte[]]$bytes) }
$writer.Dispose()
$stream.Dispose()
Write-Output 'windows/runner/resources/app_icon.ico'

$fullMaster.Dispose()
$roundedMaster.Dispose()
$maskableMaster.Dispose()
