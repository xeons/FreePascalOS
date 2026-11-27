{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  imageviewer - look at pictures

  imageviewer [FILE]

  A window showing a picture in any format libimage reads (BMP, DIB,
  ICO, CUR, GIF, JPEG, PNG, APNG, TIFF, WebP, JPEG XL; told by content,
  not name), fitted to the window or zoomed (5 % to 3200 %: +, -,
  Ctrl+wheel about the pointer, Ctrl+0 for 100 %, Ctrl+F to fit) and
  panned by dragging, the scroll bars or the arrow keys; turned and
  mirrored (Ctrl+R, Ctrl+L, Image menu); animations played, paused
  (Space) and stepped (. and ,); the folder's other images one after
  another (Right and Left while the picture fits, Page Down and Page
  Up); full screen (F11); a properties panel (Alt+Enter) with the
  format, size, depth, frames, colour profile and metadata; colours
  converted to sRGB from the file's ICC profile (View > Colour
  Management); the picture as shown copied to the clipboard (Ctrl+C)
  and saved as PNG, JPEG (with a quality), BMP, WebP, TIFF or GIF
  (Ctrl+S). FILE is shown at start; files dropped on the window are
  shown too. Files opens images here, and the desktop's Image Viewer
  icon takes dropped files.

  Prints what happens, a line each:

    settings colour-management on|off, properties on|off, toolbar on|off,
      status-bar on|off
    opened PATH FORMAT W x H, frames N, colour off|converted|not-needed|
      approximate|unsupported
    error PATH: REASON      a file that could not be read
    zoom PERCENT            the zoom changed
    orientation N           turned or flipped (EXIF's 1 to 8)
    playing on|off, frame N, full-screen on|off, properties on|off,
      colour-management on|off, dropped PATH, copied W x H,
      saved PATH FORMAT QUALITY
    exit

  The units are in userland/apps/imageviewer: ImageViewer.ViewGeometry (zoom
  and pan arithmetic), ImageViewer.Orientations (turns),
  ImageViewer.FolderImages (next and previous), ImageViewer.ImageView
  (the scrolling view), ImageViewer.Properties, ImageViewer.Saving,
  ImageViewer.MainWindow, ImageViewer.Settings and ImageViewer.Output.
}
program ImageViewer;

{$mode objfpc}
{$H+}

uses
  Windowing.Windows,
  ImageViewer.MainWindow;

var
  Window: TImageViewerWindow;
begin
  Window := TImageViewerWindow.Create;
  Window.Show;
  if ParamCount >= 1 then
    Window.OpenImage(ParamStr(1));
  RunMessageLoop;
end.
