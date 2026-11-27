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

{ Painting a laid out page into a PNG file. }
unit WebRender.Painting;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Document;

{ The viewport (or with WholeDocument the whole document) at the
  layout's scale. }
function PaintPageToPng(Layout: TDocumentLayout; const FileName: string; WholeDocument: Boolean): Boolean;

implementation

uses
  SysUtils, Math, Drawing.Colors, Drawing.Surfaces, Drawing.Rectangles, Image.Model, Image.Surfaces, Image.Codecs,
  Image.Files, Web.Paint.Painter;

function PaintPageToPng(Layout: TDocumentLayout; const FileName: string; WholeDocument: Boolean): Boolean;
var
  Painter: TDocumentPainter;
  Surface: TSurface;
  Width, Height: LongInt;
  Image: TImage;
begin
  Result := False;
  if WholeDocument and (Layout.DocumentHeight > Layout.ViewportHeight) then
  begin
    Layout.SetViewport(Layout.ViewportWidth, Ceil(Layout.DocumentHeight), Layout.Scale);
    Layout.Update;
  end;
  Width := Max(1, Round(Layout.ViewportWidth * Layout.Scale));
  Height := Max(1, Round(Layout.ViewportHeight * Layout.Scale));
  if not CreateSurface(Surface, Width, Height, ColorWhite) then
    Exit;
  Painter := TDocumentPainter.Create(Layout);
  try
    Painter.Paint(Surface, MakeRectangle(0, 0, Width, Height));
    Image := ImageTakingSurface(Surface);
    try
      SaveImage(Image, FileName, ImageFormatPng);
      Result := True;
    finally
      Image.Free;
    end;
  finally
    Painter.Free;
  end;
end;

end.
