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
  A desktop window: the wallpaper covering one display, and on the
  first display the programs' icons.

  It is a desktop to the display server (WindowDesktop): always below
  every other window, never raised over them, though it takes the
  keyboard when clicked. The icons stand in a grid of equal cells, in
  columns from the top left, each a picture above its caption, all in
  logical units. A click selects an icon (or none, on the wallpaper); a
  double click, or Enter, starts its program; the arrow keys move the
  selection. Files dragged onto an icon (from Files) are opened with its
  program (Desktop.FileDrops); the icon is selected while they are over
  it.
}
unit Desktop.DesktopWindow;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Surfaces,
  Drawing.Canvas,
  Windowing.Windows,
  Configuration.Changes,
  Windowing.DragAndDrop;

type
  TDesktopWindow = class(TWindow)
  private
    FDisplayNumber: LongInt;
    FShowsIcons: Boolean;
    FWallpaper: TSurface;
    FSelected: LongInt;
    FLastClickIndex: LongInt;
    FLastClickTime: QWord;
    { The selection before files were dragged over the icons. }
    FSelectedBeforeDrag: LongInt;
    FDragOverIcons: Boolean;
    procedure EndDragOverIcons;
    function IconCount: LongInt;
    function RowsPerColumn: LongInt;
    { Cell Index's rectangle in surface pixels. }
    function CellBounds(Index: LongInt): TRectangle;
    function PictureBounds(Index: LongInt): TRectangle;
    function CaptionBounds(Index: LongInt): TRectangle;
    function IconAt(X, Y: LongInt): LongInt;
    procedure Select(Index: LongInt);
    procedure MoveSelection(Rows, Columns: LongInt);
    procedure PaintIcon(var Canvas: TCanvas; Index: LongInt);
    procedure DesktopSettingsChanged(const Group: string; const Changes: TSettingChanges);
  protected
    procedure Paint(var Canvas: TCanvas; const Area: TRectangle); override;
    procedure Resized; override;
    procedure ThemeChanged; override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure KeyDown(Code, Character, Modifiers: LongWord); override;
    procedure CloseRequested; override;
    function DragOver(const Drag: TDragEvent): LongWord; override;
    procedure DragLeave; override;
    procedure Drop(const Drag: TDragEvent); override;
  public
    { Covers the display numbered DisplayNumber: Left, Top, Width,
      Height in logical units of the desktop. }
    constructor CreateDesktop(DisplayNumber: LongInt; Left, Top, Width, Height: LongInt; ShowsIcons: Boolean);
    destructor Destroy; override;
    { Says where each icon is (for tests). }
    procedure TellPlaces;
    property DisplayNumber: LongInt read FDisplayNumber;
  end;

implementation

uses
  Classes,
  Abi.SystemCalls,
  Sys.Time,
  Drawing.Colors,
  Windowing.Protocol,
  Windowing.Theme,
  Windowing.Connection,
  Windowing.SettingsChanges,
  Controls.Keys,
  Controls.Text,
  Desktop.Programs,
  Desktop.ProgramPictures,
  Desktop.Wallpaper,
  Desktop.Settings,
  Desktop.FileDrops,
  Desktop.Report;

const
  { Logical units: the grid's margin, a cell, the picture in it and the
    caption under it. }
  GridMargin = 10;
  CellWidth = 100;
  CellHeight = 76;
  PictureSize = 32;
  PictureTop = 6;
  CaptionTop = 42;
  CaptionHeight = 18;
  DoubleClickMilliseconds = 500;
  { How dark the shadow under a caption's letters is. }
  CaptionShadowAlpha = $C0;
  { What a selected picture is tinted with. }
  SelectedTint = $60284C82;

constructor TDesktopWindow.CreateDesktop(DisplayNumber: LongInt; Left, Top, Width, Height: LongInt;
  ShowsIcons: Boolean);
begin
  FDisplayNumber := DisplayNumber;
  FShowsIcons := ShowsIcons;
  FSelected := -1;
  FLastClickIndex := -1;
  inherited Create('Desktop', Left, Top, Width, Height, WindowDesktop);
  SubscribeToSettings(DesktopSettingsGroup, @DesktopSettingsChanged);
end;

destructor TDesktopWindow.Destroy;
begin
  UnsubscribeFromSettings(@DesktopSettingsChanged);
  FreeSurface(FWallpaper);
  inherited Destroy;
end;

function TDesktopWindow.IconCount: LongInt;
begin
  if FShowsIcons then
    Result := DesktopProgramCount
  else
    Result := 0;
end;

function TDesktopWindow.RowsPerColumn: LongInt;
begin
  Result := (ClientHeight - 2 * GridMargin) div CellHeight;
  if Result < 1 then
    Result := 1;
end;

function TDesktopWindow.CellBounds(Index: LongInt): TRectangle;
var
  Column: LongInt;
  Row: LongInt;
begin
  Column := Index div RowsPerColumn;
  Row := Index mod RowsPerColumn;
  Result := MakeRectangle(Scaled(GridMargin + Column * CellWidth), Scaled(GridMargin + Row * CellHeight),
    Scaled(CellWidth), Scaled(CellHeight));
end;

function TDesktopWindow.PictureBounds(Index: LongInt): TRectangle;
var
  Cell: TRectangle;
begin
  Cell := CellBounds(Index);
  Result := MakeRectangle(Cell.Left + (RectangleWidth(Cell) - Scaled(PictureSize)) div 2, Cell.Top + Scaled(PictureTop),
    Scaled(PictureSize), Scaled(PictureSize));
end;

function TDesktopWindow.CaptionBounds(Index: LongInt): TRectangle;
var
  Cell: TRectangle;
  Width: LongInt;
begin
  Cell := CellBounds(Index);
  Width := TextWidth(ControlFace, DesktopPrograms[Index].Caption) + Scaled(6);
  if Width > RectangleWidth(Cell) - Scaled(4) then
    Width := RectangleWidth(Cell) - Scaled(4);
  Result := MakeRectangle(Cell.Left + (RectangleWidth(Cell) - Width) div 2, Cell.Top + Scaled(CaptionTop), Width,
    Scaled(CaptionHeight));
end;

function TDesktopWindow.IconAt(X, Y: LongInt): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to IconCount - 1 do
    if RectangleContainsPoint(PictureBounds(Index), X, Y) or RectangleContainsPoint(CaptionBounds(Index), X, Y) then
      Exit(Index);
  Result := -1;
end;

procedure TDesktopWindow.Select(Index: LongInt);
begin
  if Index = FSelected then
    Exit;
  if FSelected >= 0 then
    InvalidateRectangle(CellBounds(FSelected));
  FSelected := Index;
  if FSelected >= 0 then
    InvalidateRectangle(CellBounds(FSelected));
end;

procedure TDesktopWindow.MoveSelection(Rows, Columns: LongInt);
var
  Target: LongInt;
begin
  if IconCount = 0 then
    Exit;
  if FSelected < 0 then
  begin
    Select(0);
    Exit;
  end;
  Target := FSelected + Rows + Columns * RowsPerColumn;
  if (Target >= 0) and (Target < IconCount) then
    Select(Target);
end;

procedure TDesktopWindow.PaintIcon(var Canvas: TCanvas; Index: LongInt);
var
  Picture: TRectangle;
  Caption: TRectangle;
begin
  Picture := PictureBounds(Index);
  Caption := CaptionBounds(Index);
  DrawProgramPicture(Canvas, DesktopPrograms[Index], Picture);
  if Index = FSelected then
  begin
    FillRectangle(Canvas, Picture, SelectedTint);
    FillRectangle(Canvas, Caption, Theme.Selection);
    DrawTextInBox(Canvas, ControlFace, DesktopPrograms[Index].Caption, Caption, AlignTextCenter, Theme.SelectionText);
    Exit;
  end;
  DrawTextInBox(Canvas, ControlFace, DesktopPrograms[Index].Caption, OffsetRectangle(Caption, 1, 1),
    AlignTextCenter, WithAlpha(Theme.DesktopIconTextShadow, CaptionShadowAlpha));
  DrawTextInBox(Canvas, ControlFace, DesktopPrograms[Index].Caption, Caption, AlignTextCenter, Theme.DesktopIconText);
end;

procedure TDesktopWindow.Paint(var Canvas: TCanvas; const Area: TRectangle);
var
  Index: LongInt;
begin
  if (FWallpaper.Width <> PixelWidth) or (FWallpaper.Height <> PixelHeight) then
    RenderWallpaper(FWallpaper, PixelWidth, PixelHeight);
  if FWallpaper.Pixels <> nil then
    DrawSurface(Canvas, FWallpaper, Area, Area.Left, Area.Top, False, 255)
  else
    FillRectangle(Canvas, Area, Theme.Desktop);
  for Index := 0 to IconCount - 1 do
    PaintIcon(Canvas, Index);
end;

{ A new wallpaper chosen elsewhere: drawn again (said once, by the
  first desktop window to hear of it). }
procedure TDesktopWindow.DesktopSettingsChanged(const Group: string; const Changes: TSettingChanges);
var
  Path: string;
begin
  if not ChangesInclude(Changes, WallpaperSetting) then
    Exit;
  Path := RememberedWallpaper;
  if Path <> WallpaperImagePath then
  begin
    WallpaperImagePath := Path;
    Say('wallpaper ' + Path);
  end;
  FreeSurface(FWallpaper);
  Invalidate;
end;

{ The wallpaper's colours are the theme's: drawn again. }
procedure TDesktopWindow.ThemeChanged;
begin
  FreeSurface(FWallpaper);
  inherited ThemeChanged;
end;

procedure TDesktopWindow.Resized;
begin
  inherited Resized;
  TellPlaces;
end;

procedure TDesktopWindow.TellPlaces;
var
  Index: LongInt;
  Picture: TRectangle;
begin
  for Index := 0 to IconCount - 1 do
  begin
    Picture := PictureBounds(Index);
    SayPlace('icon-' + DesktopPrograms[Index].Command, Self, (Picture.Left + Picture.Right) div 2,
      (Picture.Top + Picture.Bottom) div 2);
  end;
end;

procedure TDesktopWindow.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Index: LongInt;
  Now: QWord;
begin
  if Button <> ButtonLeft then
    Exit;
  Index := IconAt(X, Y);
  Select(Index);
  Now := UptimeMilliseconds;
  if (Index >= 0) and (Index = FLastClickIndex) and (Now - FLastClickTime <= DoubleClickMilliseconds) then
  begin
    FLastClickIndex := -1;
    StartDesktopProgram(Index);
    Exit;
  end;
  FLastClickIndex := Index;
  FLastClickTime := Now;
end;

procedure TDesktopWindow.KeyDown(Code, Character, Modifiers: LongWord);
begin
  if IsEnterKey(Code) then
  begin
    if FSelected >= 0 then
      StartDesktopProgram(FSelected);
  end
  else if Code = KeyArrowDown then
    MoveSelection(1, 0)
  else if Code = KeyArrowUp then
    MoveSelection(-1, 0)
  else if Code = KeyArrowRight then
    MoveSelection(0, 1)
  else if Code = KeyArrowLeft then
    MoveSelection(0, -1);
end;

procedure TDesktopWindow.EndDragOverIcons;
begin
  if not FDragOverIcons then
    Exit;
  FDragOverIcons := False;
  Select(FSelectedBeforeDrag);
end;

function TDesktopWindow.DragOver(const Drag: TDragEvent): LongWord;
var
  Index: LongInt;
begin
  Result := 0;
  Index := -1;
  if FShowsIcons and DragCarriesFiles(Drag) then
    Index := IconAt(Drag.X, Drag.Y);
  if Index < 0 then
  begin
    EndDragOverIcons;
    Exit;
  end;
  if not FDragOverIcons then
  begin
    FSelectedBeforeDrag := FSelected;
    FDragOverIcons := True;
  end;
  Select(Index);
  { The files stay where they are: the program opens them there. }
  Result := DropEffectLink;
end;

procedure TDesktopWindow.DragLeave;
begin
  EndDragOverIcons;
end;

procedure TDesktopWindow.Drop(const Drag: TDragEvent);
var
  Index: LongInt;
  Paths: TStringList;
begin
  Index := IconAt(Drag.X, Drag.Y);
  EndDragOverIcons;
  Paths := TStringList.Create;
  try
    if ReadDroppedPaths(Paths) then
      OpenDroppedFiles(Index, Paths);
  finally
    Paths.Free;
  end;
end;

procedure TDesktopWindow.CloseRequested;
begin
  { Alt+F4 on the desktop: the desktop stays (shutting down is in the
    Start menu). }
end;

end.
