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
  The Control Panel's list of pages: a list box whose items have the
  page's icon from the icon theme before their names (a display for
  Display, a mouse for Mouse, a calendar for Date and Time...:
  PageIconName). Without the theme's files the names stand alone, as in
  a plain list box.
}
unit ControlPanel.PageList;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.ListBox;

type
  TPageList = class(TListBox)
  private
    FIconNames: array of string;
    function HasIcons: Boolean;
  protected
    procedure PaintItem(var Canvas: TCanvas; Index: LongInt; const Row: TRectangle); override;
    function ItemIndent: LongInt; override;
  public
    { A page named Caption, its icon the theme's of page PageName. }
    procedure AddPage(const Caption, PageName: string);
    function ItemHeight: LongInt; override;
  end;

{ The theme's icon of a page (its PageName: 'display', 'sound'...). }
function PageIconName(const PageName: string): string;

implementation

uses
  Windowing.Connection,
  Controls.Icons,
  Controls.IconTheme;

const
  IconGap = 4;

function PageIconName(const PageName: string): string;
begin
  if PageName = 'display' then
    Result := 'device-display'
  else if PageName = 'mouse' then
    Result := 'device-mouse'
  else if PageName = 'keyboard' then
    Result := 'device-keyboard'
  else if PageName = 'sound' then
    Result := 'status-sound-on'
  else if PageName = 'datetime' then
    Result := 'app-calendar'
  else if PageName = 'network' then
    Result := 'network'
  else if PageName = 'users' then
    Result := 'app-contacts'
  else if PageName = 'lock' then
    Result := 'action-lock'
  else
    Result := 'app-control-panel';
end;

procedure TPageList.AddPage(const Caption, PageName: string);
begin
  SetLength(FIconNames, Length(FIconNames) + 1);
  FIconNames[High(FIconNames)] := PageIconName(PageName);
  Items.Add(Caption);
end;

function TPageList.HasIcons: Boolean;
begin
  Result := (Length(FIconNames) > 0) and ThemeIconExists(FIconNames[0]);
end;

function TPageList.ItemIndent: LongInt;
begin
  Result := 0;
  if HasIcons then
    Result := Scaled(SmallIconSize + IconGap);
end;

function TPageList.ItemHeight: LongInt;
begin
  Result := inherited ItemHeight;
  if HasIcons and (Result < Scaled(SmallIconSize + 2)) then
    Result := Scaled(SmallIconSize + 2);
end;

procedure TPageList.PaintItem(var Canvas: TCanvas; Index: LongInt; const Row: TRectangle);
var
  Size: LongInt;
begin
  inherited PaintItem(Canvas, Index, Row);
  if (Index < 0) or (Index > High(FIconNames)) or not HasIcons then
    Exit;
  Size := Scaled(SmallIconSize);
  DrawThemeIcon(Canvas, FIconNames[Index], MakeRectangle(Row.Left + Scaled(IconGap) div 2,
    Row.Top + (RectangleHeight(Row) - Size) div 2, Size, Size));
end;

end.
