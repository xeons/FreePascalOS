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
  The display server's system clipboard as the clipboard's store
  (Controls.Clipboard), shared by every program: UTF-8 text, and file
  lists (Controls.FileLists' text) offered with the plain paths as text
  beside them, for pasting into an edit box. While a program has no
  connection to a display server it keeps the contents itself.
  Installed when libcontrols loads.
}
unit Controls.SystemClipboard;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Clipboard;

type
  TSystemClipboardStore = class(TClipboardStore)
  private
    FText: string;
    FFileList: string;
  public
    function ReadText: string; override;
    procedure WriteText(const Text: string); override;
    function HoldsText: Boolean; override;
    procedure WriteFileList(const ListText, PlainText: string); override;
    function ReadFileList: string; override;
  end;

implementation

uses
  SysUtils,
  Windowing.Protocol,
  Windowing.Connection,
  Windowing.DataTransfer,
  Windowing.Clipboard;

function TSystemClipboardStore.ReadText: string;
begin
  if not IsConnected then
    Exit(FText);
  if not ReadClipboardText(Result) then
    Result := '';
end;

procedure TSystemClipboardStore.WriteText(const Text: string);
begin
  FText := Text;
  FFileList := '';
  if not IsConnected then
    Exit;
  if Text = '' then
    ClearClipboard
  else
    WriteClipboardText(Text);
end;

function TSystemClipboardStore.HoldsText: Boolean;
begin
  if not IsConnected then
    Exit(FText <> '');
  Result := ClipboardHasFormat(DataFormatText);
end;

procedure TSystemClipboardStore.WriteFileList(const ListText, PlainText: string);
var
  Offer: TDataOffer;
begin
  FText := PlainText;
  FFileList := ListText;
  if not IsConnected then
    Exit;
  Offer := TDataOffer.Create;
  Offer.Add(DataFormatFileList, TextToBytes(ListText));
  Offer.Add(DataFormatText, TextToBytes(PlainText));
  WriteClipboard(Offer);
end;

function TSystemClipboardStore.ReadFileList: string;
var
  Data: TBytes;
begin
  if not IsConnected then
    Exit(FFileList);
  if ReadClipboard(DataFormatFileList, Data) then
    Result := BytesToText(Data)
  else
    Result := '';
end;

initialization
  SetClipboardStore(TSystemClipboardStore.Create);
end.
