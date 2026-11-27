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
  The icons of the other programs' windows, for their taskbar buttons.

  The display server tells the shell each window's icon version
  (Desktop.WindowList); when it is new the icon is asked for
  (Windowing.WindowIcons): a name of the icon theme is drawn from the
  theme's file at whatever size a button wants (Controls.IconTheme), a
  window's own pictures as the server gave them, shrunk or grown to
  the button's size (made once for each size).
}
unit Desktop.TaskIcons;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas;

{ Asks for window WindowId's icon if Version is not the one known;
  True if what is known changed. }
function UpdateTaskIcon(WindowId, Version: LongWord): Boolean;
procedure ForgetTaskIcon(WindowId: LongWord);
{ How the icon is said in the shell's log: its theme name, "pictures",
  or "none". }
function TaskIconDescription(WindowId: LongWord): string;
{ Draws window WindowId's icon in Box (a square); False (and nothing
  drawn) if it has none. }
function DrawTaskIcon(const Canvas: TCanvas; WindowId: LongWord; const Box: TRectangle): Boolean;

implementation

uses
  SysUtils,
  Drawing.Colors,
  Image.Model,
  Image.Surfaces,
  Image.Resampling,
  Windowing.Protocol,
  Windowing.Connection,
  Windowing.WindowIcons,
  Controls.IconTheme,
  Controls.WindowIcons;

const
  { The size the pictures are asked for, logical units: a button's. }
  IconLogicalSize = 16;

type
  TTaskIcon = class
  public
    WindowId: LongWord;
    Version: LongWord;
    Flags: LongWord;
    Name: string;
    { The window's own pictures, as the server made them; and the last
      size made of it for a button. }
    Picture: TImage;
    Sized: TImage;
    destructor Destroy; override;
  end;

var
  Icons: array of TTaskIcon;

destructor TTaskIcon.Destroy;
begin
  Picture.Free;
  Sized.Free;
  inherited Destroy;
end;

function IndexOfIcon(WindowId: LongWord): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(Icons) do
    if Icons[Index].WindowId = WindowId then
      Exit(Index);
  Result := -1;
end;

function IconOf(WindowId: LongWord): TTaskIcon;
var
  Index: LongInt;
begin
  Index := IndexOfIcon(WindowId);
  if Index < 0 then
    Result := nil
  else
    Result := Icons[Index];
end;

procedure TakeDescription(Icon: TTaskIcon; const Described: TDescribedIcon);
begin
  FreeAndNil(Icon.Picture);
  FreeAndNil(Icon.Sized);
  Icon.Flags := Described.Flags;
  Icon.Name := Described.Name;
  if (Described.Flags and WindowIconPictures) <> 0 then
    Icon.Picture := ImageOfIconPicture(Described.Picture);
end;

function UpdateTaskIcon(WindowId, Version: LongWord): Boolean;
var
  Icon: TTaskIcon;
  Described: TDescribedIcon;
begin
  Icon := IconOf(WindowId);
  if (Icon <> nil) and (Icon.Version = Version) then
    Exit(False);
  if Icon = nil then
  begin
    Icon := TTaskIcon.Create;
    Icon.WindowId := WindowId;
    Insert(Icon, Icons, Length(Icons));
  end;
  Icon.Version := Version;
  if Version = 0 then
  begin
    Described := Default(TDescribedIcon);
    TakeDescription(Icon, Described);
    Exit(True);
  end;
  if DescribeWindowIcon(WindowId, Scaled(IconLogicalSize), Described) then
    TakeDescription(Icon, Described)
  else
    { Asked again with the next change. }
    Icon.Version := 0;
  Result := True;
end;

procedure ForgetTaskIcon(WindowId: LongWord);
var
  Index: LongInt;
begin
  Index := IndexOfIcon(WindowId);
  if Index < 0 then
    Exit;
  Icons[Index].Free;
  Delete(Icons, Index, 1);
end;

function TaskIconDescription(WindowId: LongWord): string;
var
  Icon: TTaskIcon;
begin
  Icon := IconOf(WindowId);
  if (Icon = nil) or (Icon.Flags = 0) then
    Result := 'none'
  else if (Icon.Flags and WindowIconNamed) <> 0 then
    Result := Icon.Name
  else
    Result := 'pictures';
end;

{ The window's pictures at Side x Side pixels. }
function PictureAt(Icon: TTaskIcon; Side: LongInt): TImage;
begin
  Result := nil;
  if (Icon.Picture = nil) or (Side < 1) then
    Exit;
  if (Icon.Picture.Width = Side) and (Icon.Picture.Height = Side) then
    Exit(Icon.Picture);
  if (Icon.Sized = nil) or (Icon.Sized.Width <> Side) or (Icon.Sized.Height <> Side) then
  begin
    FreeAndNil(Icon.Sized);
    Icon.Sized := ResampleImage(Icon.Picture, Side, Side, ResamplingMitchell);
  end;
  Result := Icon.Sized;
end;

function DrawTaskIcon(const Canvas: TCanvas; WindowId: LongWord; const Box: TRectangle): Boolean;
var
  Icon: TTaskIcon;
  Side: LongInt;
  Picture: TImage;
begin
  Result := False;
  Icon := IconOf(WindowId);
  if (Icon = nil) or (Icon.Flags = 0) then
    Exit;
  if (Icon.Flags and WindowIconNamed) <> 0 then
    Exit(DrawThemeIcon(Canvas, Icon.Name, Box));
  Side := RectangleWidth(Box);
  if RectangleHeight(Box) < Side then
    Side := RectangleHeight(Box);
  Picture := PictureAt(Icon, Side);
  if Picture = nil then
    Exit;
  DrawSurface(Canvas, ImageSurface(Picture), MakeRectangle(0, 0, Picture.Width, Picture.Height), Box.Left, Box.Top,
    True, AlphaOpaque);
  Result := True;
end;

end.
