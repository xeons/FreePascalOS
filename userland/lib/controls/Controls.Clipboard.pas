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
  The clipboard: text cut or copied, waiting to be pasted.

  Controls (the edit boxes) and programs use only the routines below.
  Where the text is kept is a store behind them: until the display
  server has a system clipboard (shared by every program) the store
  keeps it within the program; a store that asks the server instead can
  take its place (SetClipboardStore) without the controls changing.
}
unit Controls.Clipboard;

{$mode objfpc}
{$H+}

interface

type
  { Somewhere to keep the clipboard's text. }
  TClipboardStore = class
  public
    function ReadText: string; virtual; abstract;
    procedure WriteText(const Text: string); virtual; abstract;
    { The default reads the text; a store may know more cheaply. }
    function HoldsText: Boolean; virtual;
  end;

function ClipboardText: string;
procedure SetClipboardText(const Text: string);
function ClipboardHasText: Boolean;
{ The store used from now on (the clipboard frees it later, and frees
  the one it replaces now). }
procedure SetClipboardStore(Store: TClipboardStore);

implementation

type
  { The text kept in the program itself. }
  TProgramClipboardStore = class(TClipboardStore)
  private
    FText: string;
  public
    function ReadText: string; override;
    procedure WriteText(const Text: string); override;
  end;

var
  CurrentStore: TClipboardStore;

function TClipboardStore.HoldsText: Boolean;
begin
  Result := ReadText <> '';
end;

function TProgramClipboardStore.ReadText: string;
begin
  Result := FText;
end;

procedure TProgramClipboardStore.WriteText(const Text: string);
begin
  FText := Text;
end;

{ The store, made when first needed. }
function ActiveStore: TClipboardStore;
begin
  if CurrentStore = nil then
    CurrentStore := TProgramClipboardStore.Create;
  Result := CurrentStore;
end;

function ClipboardText: string;
begin
  Result := ActiveStore.ReadText;
end;

procedure SetClipboardText(const Text: string);
begin
  ActiveStore.WriteText(Text);
end;

function ClipboardHasText: Boolean;
begin
  Result := ActiveStore.HoldsText;
end;

procedure SetClipboardStore(Store: TClipboardStore);
begin
  if Store = CurrentStore then
    Exit;
  CurrentStore.Free;
  CurrentStore := Store;
end;

finalization
  CurrentStore.Free;
end.
