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
  Icons: a program's own (a surface) or a stock one.

  A stock icon (a text document, a folder and the folders with an
  emblem, files of each kind, a program, the drives, the home folder,
  the computer...) is the icon theme's picture of it (StockIconNames:
  /usr/share/icons/NAME.ico, Controls.IconTheme) at the box's size in
  pixels, so the size made for the display's scale. Without the
  theme's file the older stock icons are drawn as shapes for the box
  (here and in Controls.FileIcons: sharp at any size, anti-aliased),
  and the newer ones as the nearest older one (a music folder as a
  folder, a picture as a plain file).

  Marks go over an icon (DrawIconOverlay): a symbolic link shows as what
  it points to with a small arrow over it; locked, synced, updating and
  needing attention have their marks too (only the link's is drawn
  without the theme). A program's own icon is a surface scaled smoothly
  to the box (and blended by its alpha), so one picture serves the
  small and the large size.
}
unit Controls.Icons;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Drawing.Surfaces,
  Drawing.Canvas;

type
  TStockIcon = (StockIconDocument, StockIconFolder, StockIconFile, StockIconProgram, StockIconFixedDisk,
    StockIconRemovableDisk, StockIconHome, StockIconComputer,
    { Only in the theme (drawn as an older one without it). }
    StockIconFolderOpen, StockIconFolderDocuments, StockIconFolderPictures, StockIconFolderMusic,
    StockIconFolderVideos, StockIconFolderDownloads, StockIconFolderProjects, StockIconFolderPublic,
    StockIconFolderTemplates, StockIconFolderCompressed, StockIconRichDocument, StockIconSpreadsheet,
    StockIconPresentation, StockIconPdf, StockIconImage, StockIconAudio, StockIconVideo, StockIconArchive,
    StockIconSettingsFile, StockIconFont, StockIconUnknown, StockIconOpticalDisk, StockIconUsbDisk,
    StockIconMemoryCard, StockIconSolidStateDisk, StockIconNetwork, StockIconInternet, StockIconTrash,
    StockIconTrashFull, StockIconFavourites, StockIconApplications);
  { Marks drawn over an icon. }
  TIconOverlay = (OverlayNone, OverlayLink, OverlayLocked, OverlaySynced, OverlayUpdating, OverlayAttention);

const
  { The theme's name of each stock icon (its file is NAME.ico). }
  StockIconNames: array[TStockIcon] of string = ('file-text', 'folder', 'file', 'file-executable', 'drive',
    'drive-removable', 'home', 'computer', 'folder-open', 'folder-documents', 'folder-pictures', 'folder-music',
    'folder-videos', 'folder-downloads', 'folder-projects', 'folder-public', 'folder-templates', 'folder-compressed',
    'file-document', 'file-spreadsheet', 'file-presentation', 'file-pdf', 'file-image', 'file-audio', 'file-video',
    'file-archive', 'file-settings', 'file-font', 'file-unknown', 'drive-optical', 'drive-usb', 'memory-card',
    'drive-ssd', 'network', 'internet', 'trash-empty', 'trash-full', 'favourites', 'applications');
  OverlayNames: array[TIconOverlay] of string = ('', 'overlay-shortcut', 'overlay-locked', 'overlay-synced',
    'overlay-updating', 'overlay-attention');

const
  { Sizes in logical units: small icons (beside text), large icons
    (above it). }
  SmallIconSize = 16;
  LargeIconSize = 32;

procedure DrawStockIcon(const Canvas: TCanvas; Icon: TStockIcon; const Box: TRectangle);
{ The older stock icon drawn as shapes for Icon when the theme has no
  picture of it. }
function DrawnStockIcon(Icon: TStockIcon): TStockIcon;
{ Icon if it has pixels, else the stock icon Fallback. }
procedure DrawIcon(const Canvas: TCanvas; const Icon: TSurface; Fallback: TStockIcon; const Box: TRectangle);
procedure DrawIconOverlay(const Canvas: TCanvas; Overlay: TIconOverlay; const Box: TRectangle);

implementation

uses
  Drawing.Colors,
  Drawing.Rasterizer,
  Drawing.SmoothShapes,
  Drawing.Scaling,
  Controls.FileIcons,
  Controls.IconTheme;

const
  { The stock icons are designed on a grid this many steps across. }
  GridSize = 32;
  PageColor = $FFFFFFFF;
  PageOutlineColor = $FF4A4F57;
  PageFoldColor = $FFD5D9DF;
  PageLinesColor = $FF5B87C0;
  FolderColor = $FFE9C153;
  FolderTabColor = $FFD9A93A;
  FolderOutlineColor = $FF8A6418;

{ Grid point (Column, Row) of the design in Box's pixels. }
function GridPoint(const Box: TRectangle; Column, Row: LongInt): TPoint;
begin
  Result := MakePoint(Box.Left + Column * RectangleWidth(Box) div GridSize,
    Box.Top + Row * RectangleHeight(Box) div GridSize);
end;

{ A shape of grid points, filled and outlined: the outline one pixel
  wide through the points as pixel centres, the fill out to the middle
  of the outline (half a pixel on), so the two meet without a gap. }
procedure DrawOutlinedShape(const Canvas: TCanvas; const Points: array of TPoint; FillColor, OutlineColor: TColor);
var
  Filled: array of TPrecisePoint;
  Outline: array of TPrecisePoint;
  Index: LongInt;
begin
  Filled := nil;
  Outline := nil;
  SetLength(Filled, Length(Points));
  SetLength(Outline, Length(Points));
  for Index := 0 to High(Points) do
  begin
    Filled[Index] := PrecisePoint(Points[Index].X + 0.5, Points[Index].Y + 0.5);
    Outline[Index] := PrecisePoint(Points[Index].X, Points[Index].Y);
  end;
  FillSmoothPolygon(Canvas, Filled, FillColor);
  DrawSmoothPolygonOutline(Canvas, Outline, 1, OutlineColor);
end;

procedure DrawDocument(const Canvas: TCanvas; const Box: TRectangle);
var
  Page: array[0..4] of TPoint;
  Fold: array[0..2] of TPoint;
  Row: LongInt;
  Step: LongInt;
  Left: LongInt;
  Right: LongInt;
begin
  { A page with its top right corner folded over. }
  Page[0] := GridPoint(Box, 6, 1);
  Page[1] := GridPoint(Box, 19, 1);
  Page[2] := GridPoint(Box, 26, 8);
  Page[3] := GridPoint(Box, 26, 31);
  Page[4] := GridPoint(Box, 6, 31);
  DrawOutlinedShape(Canvas, Page, PageColor, PageOutlineColor);
  Fold[0] := GridPoint(Box, 19, 1);
  Fold[1] := GridPoint(Box, 19, 8);
  Fold[2] := GridPoint(Box, 26, 8);
  DrawOutlinedShape(Canvas, Fold, PageFoldColor, PageOutlineColor);
  { Lines of text: fewer of them on a small page, so they stay apart. }
  Step := 4;
  if RectangleHeight(Box) < 24 then
    Step := 6;
  Left := GridPoint(Box, 10, 0).X;
  Right := GridPoint(Box, 23, 0).X;
  Row := 12;
  while Row <= 27 do
  begin
    DrawHorizontalLine(Canvas, Left, Right, GridPoint(Box, 0, Row).Y, PageLinesColor);
    Row := Row + Step;
  end;
end;

procedure DrawFolder(const Canvas: TCanvas; const Box: TRectangle);
var
  Tab: array[0..3] of TPoint;
  Body: array[0..3] of TPoint;
begin
  { A tab sticking up behind the body, at the left. }
  Tab[0] := GridPoint(Box, 2, 9);
  Tab[1] := GridPoint(Box, 4, 5);
  Tab[2] := GridPoint(Box, 13, 5);
  Tab[3] := GridPoint(Box, 15, 9);
  DrawOutlinedShape(Canvas, Tab, FolderTabColor, FolderOutlineColor);
  Body[0] := GridPoint(Box, 2, 9);
  Body[1] := GridPoint(Box, 30, 9);
  Body[2] := GridPoint(Box, 30, 27);
  Body[3] := GridPoint(Box, 2, 27);
  DrawOutlinedShape(Canvas, Body, FolderColor, FolderOutlineColor);
end;

function DrawnStockIcon(Icon: TStockIcon): TStockIcon;
begin
  case Icon of
    StockIconFolderOpen..StockIconFolderCompressed:
      Result := StockIconFolder;
    StockIconRichDocument..StockIconPdf:
      Result := StockIconDocument;
    StockIconImage..StockIconUnknown, StockIconTrash, StockIconTrashFull:
      Result := StockIconFile;
    StockIconOpticalDisk, StockIconSolidStateDisk:
      Result := StockIconFixedDisk;
    StockIconUsbDisk, StockIconMemoryCard:
      Result := StockIconRemovableDisk;
    StockIconNetwork, StockIconInternet:
      Result := StockIconComputer;
    StockIconFavourites, StockIconApplications:
      Result := StockIconProgram;
  else
    Result := Icon;
  end;
end;

procedure DrawStockIcon(const Canvas: TCanvas; Icon: TStockIcon; const Box: TRectangle);
begin
  if RectangleIsEmpty(Box) then
    Exit;
  if DrawThemeIcon(Canvas, StockIconNames[Icon], Box) then
    Exit;
  case DrawnStockIcon(Icon) of
    StockIconDocument: DrawDocument(Canvas, Box);
    StockIconFolder: DrawFolder(Canvas, Box);
    StockIconFile: DrawBlankPage(Canvas, Box);
    StockIconProgram: DrawProgramIcon(Canvas, Box);
    StockIconFixedDisk: DrawFixedDisk(Canvas, Box);
    StockIconRemovableDisk: DrawRemovableDisk(Canvas, Box);
    StockIconHome: DrawHome(Canvas, Box);
    StockIconComputer: DrawComputer(Canvas, Box);
  else
    DrawBlankPage(Canvas, Box);
  end;
end;

procedure DrawIconOverlay(const Canvas: TCanvas; Overlay: TIconOverlay; const Box: TRectangle);
begin
  if (Overlay = OverlayNone) or RectangleIsEmpty(Box) then
    Exit;
  if DrawThemeIcon(Canvas, OverlayNames[Overlay], Box) then
    Exit;
  if Overlay = OverlayLink then
    DrawLinkOverlay(Canvas, Box);
end;

procedure DrawIcon(const Canvas: TCanvas; const Icon: TSurface; Fallback: TStockIcon; const Box: TRectangle);
begin
  if (Icon.Pixels <> nil) and (Icon.Width > 0) and (Icon.Height > 0) then
    DrawSurfaceScaled(Canvas, Icon, SurfaceBounds(Icon), Box, True)
  else
    DrawStockIcon(Canvas, Fallback, Box);
end;

end.
