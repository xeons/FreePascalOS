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
  The icon theme on screen: icon NAME from its file in /usr/share/icons
  (Controls.IconFiles) drawn into a box, at the box's size in pixels
  (so at the display's scale: a 16 unit box is 20 pixels at 125 %, and
  the 20 pixel picture is drawn), or put in an image list with every
  size it has.

  Each function says whether the icon was there: when it is not (no
  file, a broken one), the caller draws its own picture instead, as the
  stock icons (Controls.Icons) and the taskbar's pictures do, so the
  system still has icons without the theme's files.
}
unit Controls.IconTheme;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.ImageList;

{ Draws icon Name as large as fits in Box (square, centred); False (and
  nothing drawn) if it has no file. }
function DrawThemeIcon(const Canvas: TCanvas; const Name: string; const Box: TRectangle): Boolean;
{ Draws it LogicalSize units across (at the display's scale) with its
  top left at (X, Y), pixels. }
function DrawThemeIconAt(const Canvas: TCanvas; const Name: string; X, Y, LogicalSize: LongInt): Boolean;
{ A new picture in List with the sizes of icon Name the list can use
  (up to three times its logical size: 300 %); -1 if it has no file. }
function AddThemeIcon(List: TImageList; const Name: string): LongInt;
function ThemeIconExists(const Name: string): Boolean;

implementation

uses
  Drawing.Colors,
  Image.Model,
  Image.Surfaces,
  Windowing.Connection,
  Controls.IconFiles;

const
  { The largest scale an image list's pictures are wanted at. }
  MostUsefulScale = 3;

function ThemeIconExists(const Name: string): Boolean;
begin
  Result := IconFileExists(Name);
end;

procedure DrawPicture(const Canvas: TCanvas; Picture: TImage; X, Y: LongInt);
begin
  DrawSurface(Canvas, ImageSurface(Picture), MakeRectangle(0, 0, Picture.Width, Picture.Height), X, Y, True,
    AlphaOpaque);
end;

function DrawThemeIcon(const Canvas: TCanvas; const Name: string; const Box: TRectangle): Boolean;
var
  Side: LongInt;
  Picture: TImage;
begin
  Side := RectangleWidth(Box);
  if RectangleHeight(Box) < Side then
    Side := RectangleHeight(Box);
  if Side <= 0 then
    Exit(IconFileExists(Name));
  Picture := IconPicture(Name, Side);
  Result := Picture <> nil;
  if Result then
    DrawPicture(Canvas, Picture, Box.Left + (RectangleWidth(Box) - Side) div 2,
      Box.Top + (RectangleHeight(Box) - Side) div 2);
end;

function DrawThemeIconAt(const Canvas: TCanvas; const Name: string; X, Y, LogicalSize: LongInt): Boolean;
var
  Side: LongInt;
begin
  Side := Scaled(LogicalSize);
  Result := DrawThemeIcon(Canvas, Name, MakeRectangle(X, Y, Side, Side));
end;

function AddThemeIcon(List: TImageList; const Name: string): LongInt;
var
  IconFile: TIconFile;
  Largest: LongInt;
  Entry: LongInt;
  Picture: TImage;
begin
  Result := -1;
  if List = nil then
    Exit;
  IconFile := FindIconFile(Name);
  if IconFile = nil then
    Exit;
  Largest := List.Width;
  if List.Height > Largest then
    Largest := List.Height;
  Largest := Largest * MostUsefulScale;
  for Entry := 0 to IconFile.EntryCount - 1 do
  begin
    if IconFile.EntryWidth(Entry) > Largest then
      Continue;
    Picture := IconFile.Picture(IconFile.EntryWidth(Entry));
    if Picture = nil then
      Continue;
    if Result < 0 then
      Result := List.Add(Picture)
    else
      List.AddVariant(Result, Picture);
  end;
  { No entry small enough: the smallest there is. }
  if Result < 0 then
  begin
    Picture := IconFile.Picture(IconFile.EntryWidth(IconFile.EntryForSize(Largest)));
    if Picture <> nil then
      Result := List.Add(Picture);
  end;
end;

end.
