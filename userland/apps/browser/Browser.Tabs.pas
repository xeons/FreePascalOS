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
  A browser tab: its web view and what the tab strip shows of it (the
  page's title, or its address while it has none, and a copy of its
  icon), and what the address bar held while it was edited.
}
unit Browser.Tabs;

{$mode objfpc}
{$H+}

interface

uses
  Image.Model,
  WebView.Control;

type
  TBrowserTab = class
  public
    View: TWebView;
    Icon: TImage;
    { The address bar's text while it is being edited (kept when the
      tab is left). }
    TypedAddress: string;
    Typing: Boolean;
    destructor Destroy; override;
    { What the tab is called: the title, else the address, else "New Tab". }
    function Caption: string;
    procedure TakeIcon(Image: TImage);
  end;

{ The address as the address bar shows it ('' for the blank and home pages). }
function ShownAddress(const Url: string): string;

implementation

uses
  SysUtils;

destructor TBrowserTab.Destroy;
begin
  Icon.Free;
  inherited Destroy;
end;

function ShownAddress(const Url: string): string;
begin
  if (Url = 'about:blank') or (Url = 'about:home') then
    Result := ''
  else
    Result := Url;
end;

function TBrowserTab.Caption: string;
begin
  Result := Trim(View.Title);
  if Result = '' then
    Result := ShownAddress(View.Url);
  if Result = '' then
    Result := 'New Tab';
end;

procedure TBrowserTab.TakeIcon(Image: TImage);
begin
  FreeAndNil(Icon);
  if Image <> nil then
    Icon := Image.Clone;
end;

end.
