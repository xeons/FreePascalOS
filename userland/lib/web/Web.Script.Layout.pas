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
  Answers to script's layout questions from a document layout (CSSOM View and
  getComputedStyle, libweb's TScriptLayout): every question first brings
  style and layout up to date (a synchronous layout, as browsers do when
  script reads geometry), then reads the boxes. Its owner (the web view,
  webbrowse) points it at its
  current layout and painter (nil between documents: no boxes).
}
unit Web.Script.Layout;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom,
  Web.ScriptEnvironment,
  Web.Layout.Document,
  Web.Paint.Painter;

type
  TDocumentScriptLayout = class(TScriptLayout)
  private
    function Ready: Boolean;
  public
    Layout: TDocumentLayout;
    Painter: TDocumentPainter;
    { The view scrolled (it repaints): called after ScrollTo. }
    OnScrolled: procedure of object;
    function BorderBox(Element: TElement; out X, Y, Width, Height: Double): Boolean; override;
    function ScrollGeometry(Element: TElement; out ClientLeft, ClientTop, ClientWidth, ClientHeight, ScrollWidth,
      ScrollHeight, ScrollLeft, ScrollTop: Double): Boolean; override;
    procedure ScrollTo(Element: TElement; Left, Top: Double); override;
    procedure ViewportScroll(out Left, Top: Double); override;
    function ElementAtPoint(X, Y: Double): TElement; override;
    function ComputedValue(Element: TElement; const PropertyName: string): string; override;
  end;

implementation

uses
  Css.ComputedStyle,
  Css.PropertyIds,
  Css.Properties,
  Web.Layout.Boxes,
  Web.Style.NodeData;

function TDocumentScriptLayout.Ready: Boolean;
begin
  Result := Layout <> nil;
  if Result and Layout.NeedsUpdate then
    Layout.Update;
end;

function TDocumentScriptLayout.BorderBox(Element: TElement; out X, Y, Width, Height: Double): Boolean;
var
  BoxX, BoxY, BoxWidth, BoxHeight: Single;
begin
  X := 0;
  Y := 0;
  Width := 0;
  Height := 0;
  Result := Ready and Layout.NodeBounds(Element, BoxX, BoxY, BoxWidth, BoxHeight);
  if Result then
  begin
    X := BoxX;
    Y := BoxY;
    Width := BoxWidth;
    Height := BoxHeight;
  end;
end;

function TDocumentScriptLayout.ScrollGeometry(Element: TElement; out ClientLeft, ClientTop, ClientWidth, ClientHeight,
  ScrollWidth, ScrollHeight, ScrollLeft, ScrollTop: Double): Boolean;
var
  Box: TLayoutBox;
begin
  ClientLeft := 0;
  ClientTop := 0;
  ClientWidth := 0;
  ClientHeight := 0;
  ScrollWidth := 0;
  ScrollHeight := 0;
  ScrollLeft := 0;
  ScrollTop := 0;
  Result := False;
  if not Ready then
    Exit;
  Box := Layout.BoxOf(Element);
  if (Box = nil) or (Box.Kind in [bkInline, bkText]) then
    Exit;
  ClientLeft := Box.Border[sideLeft];
  ClientTop := Box.Border[sideTop];
  ClientWidth := Box.Width - Box.Border[sideLeft] - Box.Border[sideRight];
  ClientHeight := Box.Height - Box.Border[sideTop] - Box.Border[sideBottom];
  if ClientWidth < 0 then
    ClientWidth := 0;
  if ClientHeight < 0 then
    ClientHeight := 0;
  if bfScrollContainer in Box.Flags then
  begin
    ScrollWidth := Box.ScrollWidth;
    ScrollHeight := Box.ScrollHeight;
    ScrollLeft := Box.ScrollX;
    ScrollTop := Box.ScrollY;
  end;
  if Element = Element.NodeDocument.DocumentElement then
  begin
    ScrollWidth := Layout.DocumentWidth;
    ScrollHeight := Layout.DocumentHeight;
  end;
  if ScrollWidth < ClientWidth then
    ScrollWidth := ClientWidth;
  if ScrollHeight < ClientHeight then
    ScrollHeight := ClientHeight;
  Result := True;
end;

procedure TDocumentScriptLayout.ScrollTo(Element: TElement; Left, Top: Double);
begin
  if not Ready then
    Exit;
  Layout.SetScrollOffset(Element, Left, Top);
  if Assigned(OnScrolled) then
    OnScrolled;
end;

procedure TDocumentScriptLayout.ViewportScroll(out Left, Top: Double);
var
  X, Y: Single;
begin
  Left := 0;
  Top := 0;
  if Layout = nil then
    Exit;
  Layout.GetScrollOffset(nil, X, Y);
  Left := X;
  Top := Y;
end;

function TDocumentScriptLayout.ElementAtPoint(X, Y: Double): TElement;
begin
  Result := nil;
  if not Ready or (Painter = nil) then
    Exit;
  Painter.Refresh;
  Result := Painter.HitTest(X, Y).Element;
end;

function TDocumentScriptLayout.ComputedValue(Element: TElement; const PropertyName: string): string;
var
  Style: TCssComputedStyle;
  Id: TCssPropertyId;
begin
  Result := '';
  if not Ready then
    Exit;
  Style := StyleOf(Element);
  if Style = nil then
    Exit;
  Id := PropertyByName(PropertyName);
  if Id = cpCustom then
    Exit(Style.CustomProperty(PropertyName));
  if Id = cpInvalid then
    Exit;
  Result := Style.SerializeProperty(Id);
end;

end.
