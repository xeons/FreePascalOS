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
  The system clipboard, which the display server keeps for every
  program.

  Writing puts data on it in one or more formats (DataFormat*: text as
  UTF-8, an image as PNG or raw pixels, a file list): WriteClipboardText
  for text, WriteClipboard for a TDataOffer of any formats, made when
  first pasted (Windowing.DataTransfer). The program owns the clipboard
  until another writes to it; whatever it had not given yet is given
  when it ends, so the clipboard keeps it. Reading asks for one format
  (ReadClipboard, ReadClipboardText), and ClipboardFormats says which
  there are. A program may hear of every change (WatchClipboard: the
  message loop calls OnClipboardChanged).

  Everything is strings and bytes; libcontrols' clipboard
  (Controls.Clipboard) is built on this, and programs with images turn
  them into PNG or raw pixels themselves.
}
unit Windowing.Clipboard;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Windowing.Protocol,
  Windowing.DataTransfer;

type
  { Formats: what the clipboard holds now (DataFormatBit of each);
    Owned: this program put it there. }
  TClipboardChangedHandler = procedure(Formats: LongWord; Owned: Boolean) of object;

var
  { Called from the message loop when the clipboard changes, once
    WatchClipboard asked for it. }
  OnClipboardChanged: TClipboardChangedHandler;

{ Puts Offer on the clipboard (taken: freed when the clipboard changes). }
procedure WriteClipboard(Offer: TDataOffer);
{ Puts Text on the clipboard (as UTF-8 text). }
procedure WriteClipboardText(const Text: string);
{ Puts Data on the clipboard as Format alone. }
procedure WriteClipboardBytes(Format: LongWord; const Data: TBytes);
{ Empties the clipboard. }
procedure ClearClipboard;
{ The formats on the clipboard now (DataFormatBit of each; 0: empty, or
  no display server). }
function ClipboardFormats: LongWord;
function ClipboardHasFormat(Format: LongWord): Boolean;
{ The clipboard's Format; False if it has none. }
function ReadClipboard(Format: LongWord; out Data: TBytes): Boolean;
{ The clipboard's text; False if it has none. }
function ReadClipboardText(out Text: string): Boolean;
{ True while what is on the clipboard is this program's. }
function OwnsClipboard: Boolean;
{ Asks to hear of the clipboard's changes (OnClipboardChanged), or not. }
procedure WatchClipboard(Watch: Boolean);
{ Whether an event of Kind is about the clipboard (or data this program
  asked for that came too late). }
function IsClipboardEvent(Kind: LongWord): Boolean;
{ Acts on such an event (the message loop calls it). }
procedure DeliverClipboardEvent(var Message: TWindowMessage);

implementation

uses
  Abi.SystemCalls,
  Sys.Objects,
  Windowing.Connection;

const
  ReplyTimeout = 5000;

procedure WriteClipboard(Offer: TDataOffer);
begin
  OfferData(DataSourceClipboard, Offer);
end;

procedure WriteClipboardBytes(Format: LongWord; const Data: TBytes);
var
  Offer: TDataOffer;
begin
  Offer := TDataOffer.Create;
  Offer.Add(Format, Data);
  WriteClipboard(Offer);
end;

procedure WriteClipboardText(const Text: string);
begin
  WriteClipboardBytes(DataFormatText, TextToBytes(Text));
end;

procedure ClearClipboard;
begin
  OfferData(DataSourceClipboard, nil);
end;

function OwnsClipboard: Boolean;
begin
  Result := CurrentOffer(DataSourceClipboard) <> nil;
end;

function ClipboardFormats: LongWord;
var
  Message: TWindowMessage;
begin
  if OwnsClipboard then
    Exit(CurrentOffer(DataSourceClipboard).Formats);
  Result := 0;
  if not IsConnected then
    Exit;
  Message := NewMessage(RequestDescribeClipboard, 0);
  SendRequest(Message, -1);
  if WaitForEvent(EventClipboardFormats, ReplyTimeout, Message) then
    Result := Message.Flags;
end;

function ClipboardHasFormat(Format: LongWord): Boolean;
begin
  Result := (ClipboardFormats and DataFormatBit(Format)) <> 0;
end;

function ReadClipboard(Format: LongWord; out Data: TBytes): Boolean;
begin
  Result := AskData(DataSourceClipboard, Format, Data);
end;

function ReadClipboardText(out Text: string): Boolean;
var
  Data: TBytes;
begin
  Result := ReadClipboard(DataFormatText, Data);
  Text := BytesToText(Data);
end;

procedure WatchClipboard(Watch: Boolean);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(RequestWatchClipboard, 0);
  Message.Value := Ord(Watch);
  SendRequest(Message, -1);
end;

function IsClipboardEvent(Kind: LongWord): Boolean;
begin
  Result := (Kind = EventClipboardChanged) or (Kind = EventClipboardFormats) or (Kind = EventClipboardLost) or
    (Kind = EventDataDelivered);
end;

procedure DeliverClipboardEvent(var Message: TWindowMessage);
var
  Section: Int64;
begin
  case Message.Kind of
    EventClipboardLost:
      ForgetOfferNumbered(DataSourceClipboard, Message.Code);
    EventClipboardChanged:
      if Assigned(OnClipboardChanged) then
        OnClipboardChanged(Message.Flags, Message.Code <> 0);
    EventDataDelivered:
      begin
        { Nobody waits for it any more. }
        Section := TakeMessageHandle(Message);
        if Section >= 0 then
          CloseHandle(Section);
      end;
  end;
end;

end.
