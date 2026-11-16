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
  The clipboard: text cut or copied, and files, waiting to be pasted.

  Controls (the edit boxes) and programs use only the routines below.
  Where it is kept is a store behind them: within the program by
  default; libcontrols puts the display server's system clipboard in
  its place when it loads (Controls.SystemClipboard), so that every
  program shares it. Another store can take its place
  (SetClipboardStore) without the controls changing. This unit needs
  no display server, so it builds on the host too.
}
unit Controls.Clipboard;

{$mode objfpc}
{$H+}

interface

type
  { Somewhere to keep the clipboard's contents. }
  TClipboardStore = class
  public
    function ReadText: string; virtual; abstract;
    procedure WriteText(const Text: string); virtual; abstract;
    { The default reads the text; a store may know more cheaply. }
    function HoldsText: Boolean; virtual;
    { A file list (its text) and the same files as plain text; the
      default keeps the list as the text. }
    procedure WriteFileList(const ListText, PlainText: string); virtual;
    { The file list's text ('' if none); the default reads the text. }
    function ReadFileList: string; virtual;
  end;

function ClipboardText: string;
{ Empty text empties the clipboard. }
procedure SetClipboardText(const Text: string);
function ClipboardHasText: Boolean;
{ A file list (Controls.FileLists has the format) with the files as
  plain text, and the list read back ('' if the clipboard has none). }
procedure SetClipboardFileListText(const ListText, PlainText: string);
function ClipboardFileListText: string;
{ The store used from now on (the clipboard frees it later, and frees
  the one it replaces now). }
procedure SetClipboardStore(Store: TClipboardStore);

implementation

type
  { Kept within the program. }
  TProgramClipboardStore = class(TClipboardStore)
  private
    FText: string;
    FFileList: string;
  public
    function ReadText: string; override;
    procedure WriteText(const Text: string); override;
    procedure WriteFileList(const ListText, PlainText: string); override;
    function ReadFileList: string; override;
  end;

var
  CurrentStore: TClipboardStore;

function TClipboardStore.HoldsText: Boolean;
begin
  Result := ReadText <> '';
end;

procedure TClipboardStore.WriteFileList(const ListText, PlainText: string);
begin
  WriteText(ListText);
end;

function TClipboardStore.ReadFileList: string;
begin
  Result := ReadText;
end;

function TProgramClipboardStore.ReadText: string;
begin
  Result := FText;
end;

procedure TProgramClipboardStore.WriteText(const Text: string);
begin
  FText := Text;
  FFileList := '';
end;

procedure TProgramClipboardStore.WriteFileList(const ListText, PlainText: string);
begin
  FText := PlainText;
  FFileList := ListText;
end;

function TProgramClipboardStore.ReadFileList: string;
begin
  Result := FFileList;
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

procedure SetClipboardFileListText(const ListText, PlainText: string);
begin
  ActiveStore.WriteFileList(ListText, PlainText);
end;

function ClipboardFileListText: string;
begin
  Result := ActiveStore.ReadFileList;
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
