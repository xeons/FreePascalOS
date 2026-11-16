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
  Data going between programs through the display server: the
  clipboard's and a drag's (DataSource*), in formats (DataFormat*).

  A program offers data as a TDataOffer: the formats it has and, for
  each, the bytes or a way to make them (Render, overridden: an image
  is encoded as PNG only if someone pastes a PNG). OfferData hands it to
  the server, which asks for a format the first time a program wants it
  (EventDataRender, answered here as soon as it arrives:
  Windowing.Connection) and keeps what it was given, so the clipboard
  outlives the program; GiveEveryFormat gives the rest at once, which a
  program does before it ends (this unit does for the clipboard when the
  program finishes). AskData asks for one format: what this program
  offered itself is read here, without asking the server.

  Bytes travel in sections: ProvideData copies them into a new one for
  the server, and what the server delivers comes in one the program
  maps, copies and closes.
}
unit Windowing.DataTransfer;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Windowing.Protocol;

type
  { Data in one or more formats. }
  TDataOffer = class
  private
    FFormats: array of LongWord;
    FData: array of TBytes;
    FMade: array of Boolean;
    FGiven: array of Boolean;
    function IndexOf(Format: LongWord): LongInt;
  protected
    { The bytes of Format (one AddLater named), made the first time they
      are wanted; the default has none. }
    function Render(Format: LongWord): TBytes; virtual;
  public
    { Format with its bytes. }
    procedure Add(Format: LongWord; const Data: TBytes);
    { Format, made by Render when first wanted. }
    procedure AddLater(Format: LongWord);
    { The formats (DataFormatBit of each). }
    function Formats: LongWord;
    function Holds(Format: LongWord): Boolean;
    { The bytes of Format (made now if they were not yet); empty if it
      has no such format. }
    function DataOf(Format: LongWord): TBytes;
  end;

{ Text as UTF-8 bytes, and back. }
function TextToBytes(const Text: string): TBytes;
function BytesToText(const Data: TBytes): string;
{ "text", "png", "bgra", "files"; and the format a name means (0: none). }
function DataFormatName(Format: LongWord): string;
function DataFormatFromName(const Name: string): LongWord;

{ Offer becomes Source's data (this unit frees it when it is replaced
  or forgotten; nil offers nothing: an empty clipboard). }
procedure OfferData(Source: LongWord; Offer: TDataOffer);
{ What this program offers for Source now (nil: nothing). }
function CurrentOffer(Source: LongWord): TDataOffer;
{ Frees what this program offered for Source, telling nobody (another
  program offers now, or the drag is over). }
procedure ForgetOffer(Source: LongWord);
{ Forgets the offer for Source if it is the one numbered Number (the
  server says which of this program's offers it lost: one made since is
  kept). }
procedure ForgetOfferNumbered(Source, Number: LongWord);
{ Gives the server every format of this program's offer for Source it
  has not given yet. }
procedure GiveEveryFormat(Source: LongWord);
{ The bytes of Format from Source; False if there are none (or no
  answer within a while). }
function AskData(Source, Format: LongWord; out Data: TBytes): Boolean;
{ Sends Data as Source's Format (Available False: it cannot be made). }
procedure ProvideData(Source, Format: LongWord; const Data: TBytes; Available: Boolean = True);
{ Copies Length bytes out of Section (closing it); False if it cannot be
  mapped. }
function ReadSection(Section: Int64; Length: QWord; out Data: TBytes): Boolean;

implementation

uses
  Abi.SystemCalls,
  Sys.Objects,
  Sys.Time,
  Windowing.Connection;

const
  { Delayed rendering may encode a large image, slowly under emulation. }
  DataReplyTimeout = 30000;

var
  Offers: array[DataSourceClipboard..DataSourceDrag] of TDataOffer;
  { How many offers this program made for each source: the server is
    told each one's number (Code of RequestOfferData). }
  OfferNumbers: array[DataSourceClipboard..DataSourceDrag] of LongWord;

{ --- TDataOffer ----------------------------------------------------------------- }

function TDataOffer.IndexOf(Format: LongWord): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(FFormats) do
    if FFormats[Index] = Format then
      Exit(Index);
  Result := -1;
end;

function TDataOffer.Render(Format: LongWord): TBytes;
begin
  Result := nil;
end;

procedure TDataOffer.Add(Format: LongWord; const Data: TBytes);
var
  Index: LongInt;
begin
  Index := IndexOf(Format);
  if Index < 0 then
  begin
    Index := Length(FFormats);
    SetLength(FFormats, Index + 1);
    SetLength(FData, Index + 1);
    SetLength(FMade, Index + 1);
    SetLength(FGiven, Index + 1);
  end;
  FFormats[Index] := Format;
  FData[Index] := Data;
  FMade[Index] := True;
  FGiven[Index] := False;
end;

procedure TDataOffer.AddLater(Format: LongWord);
begin
  Add(Format, nil);
  FMade[IndexOf(Format)] := False;
end;

function TDataOffer.Formats: LongWord;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to High(FFormats) do
    Result := Result or DataFormatBit(FFormats[Index]);
end;

function TDataOffer.Holds(Format: LongWord): Boolean;
begin
  Result := IndexOf(Format) >= 0;
end;

function TDataOffer.DataOf(Format: LongWord): TBytes;
var
  Index: LongInt;
begin
  Index := IndexOf(Format);
  if Index < 0 then
    Exit(nil);
  if not FMade[Index] then
  begin
    FData[Index] := Render(Format);
    FMade[Index] := True;
  end;
  Result := FData[Index];
end;

{ --- Formats --------------------------------------------------------------------- }

function TextToBytes(const Text: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(Text));
  if Length(Text) > 0 then
    Move(Text[1], Result[0], Length(Text));
end;

function BytesToText(const Data: TBytes): string;
begin
  Result := '';
  SetLength(Result, Length(Data));
  if Length(Data) > 0 then
    Move(Data[0], Result[1], Length(Data));
end;

function DataFormatName(Format: LongWord): string;
begin
  case Format of
    DataFormatText: Result := 'text';
    DataFormatPng: Result := 'png';
    DataFormatBgra: Result := 'bgra';
    DataFormatFileList: Result := 'files';
  else
    Result := 'format' + IntToStr(Format);
  end;
end;

function DataFormatFromName(const Name: string): LongWord;
var
  Format: LongWord;
begin
  for Format := 1 to DataFormatCount do
    if SameText(Name, DataFormatName(Format)) then
      Exit(Format);
  Result := 0;
end;

{ --- Sections ---------------------------------------------------------------------- }

function ReadSection(Section: Int64; Length: QWord; out Data: TBytes): Boolean;
var
  Bytes: Pointer;
begin
  Data := nil;
  Result := Length = 0;
  if Section < 0 then
    Exit;
  if Length > 0 then
  begin
    Bytes := MapSection(Section, 0, Length);
    if Bytes <> nil then
    begin
      SetLength(Data, Length);
      Move(Bytes^, Data[0], Length);
      UnmapSection(Bytes);
      Result := True;
    end;
  end;
  CloseHandle(Section);
end;

{ Sends a provide request saying the format cannot be had. }
procedure ProvideNothing(var Message: TWindowMessage);
begin
  Message.Flags := 0;
  Message.Width := 0;
  SendRequest(Message, -1);
end;

procedure ProvideData(Source, Format: LongWord; const Data: TBytes; Available: Boolean);
var
  Message: TWindowMessage;
  Section: Int64;
  Bytes: Pointer;
begin
  Message := NewMessage(RequestProvideData, 0);
  Message.Value := LongInt(Source);
  Message.Code := Format;
  if not Available or (Length(Data) > MaximumDataBytes) then
  begin
    ProvideNothing(Message);
    Exit;
  end;
  Message.Flags := DataAvailable;
  Message.Width := Length(Data);
  if Length(Data) = 0 then
  begin
    SendRequest(Message, -1);
    Exit;
  end;
  Section := CreateSection(Length(Data));
  if Section < 0 then
  begin
    ProvideNothing(Message);
    Exit;
  end;
  Bytes := MapSection(Section, 0, Length(Data));
  if Bytes = nil then
  begin
    CloseHandle(Section);
    ProvideNothing(Message);
    Exit;
  end;
  Move(Data[0], Bytes^, Length(Data));
  UnmapSection(Bytes);
  { The server takes a reference of its own. }
  SendRequest(Message, Section);
  CloseHandle(Section);
end;

{ --- Offers ------------------------------------------------------------------------- }

function ValidSource(Source: LongWord): Boolean;
begin
  Result := Source <= DataSourceDrag;
end;

procedure OfferData(Source: LongWord; Offer: TDataOffer);
var
  Message: TWindowMessage;
begin
  if not ValidSource(Source) then
  begin
    Offer.Free;
    Exit;
  end;
  if Offers[Source] <> Offer then
    Offers[Source].Free;
  Offers[Source] := Offer;
  Inc(OfferNumbers[Source]);
  Message := NewMessage(RequestOfferData, 0);
  Message.Value := LongInt(Source);
  Message.Code := OfferNumbers[Source];
  if Offer <> nil then
    Message.Flags := Offer.Formats;
  SendRequest(Message, -1);
end;

function CurrentOffer(Source: LongWord): TDataOffer;
begin
  Result := nil;
  if ValidSource(Source) then
    Result := Offers[Source];
end;

procedure ForgetOffer(Source: LongWord);
begin
  if not ValidSource(Source) then
    Exit;
  FreeAndNil(Offers[Source]);
end;

procedure ForgetOfferNumbered(Source, Number: LongWord);
begin
  if ValidSource(Source) and (OfferNumbers[Source] = Number) then
    ForgetOffer(Source);
end;

procedure GiveFormat(Source, Format: LongWord);
var
  Offer: TDataOffer;
  Index: LongInt;
begin
  Offer := CurrentOffer(Source);
  Index := -1;
  if Offer <> nil then
    Index := Offer.IndexOf(Format);
  if Index < 0 then
  begin
    ProvideData(Source, Format, nil, False);
    Exit;
  end;
  ProvideData(Source, Format, Offer.DataOf(Format));
  Offer.FGiven[Index] := True;
end;

procedure GiveEveryFormat(Source: LongWord);
var
  Offer: TDataOffer;
  Index: LongInt;
begin
  Offer := CurrentOffer(Source);
  if (Offer = nil) or not IsConnected then
    Exit;
  for Index := 0 to High(Offer.FFormats) do
    if not Offer.FGiven[Index] then
      GiveFormat(Source, Offer.FFormats[Index]);
end;

procedure AnswerRenderRequest(const Message: TWindowMessage);
begin
  if ValidSource(LongWord(Message.Value)) then
    GiveFormat(LongWord(Message.Value), Message.Code);
end;

{ Closes Section if it is a handle. }
procedure DropSection(Section: Int64);
begin
  if Section >= 0 then
    CloseHandle(Section);
end;

function AskData(Source, Format: LongWord; out Data: TBytes): Boolean;
var
  Message: TWindowMessage;
  Deadline: QWord;
  Now: QWord;
  Section: Int64;
begin
  Data := nil;
  Result := False;
  if not ValidSource(Source) then
    Exit;
  { What this program offered is here already. }
  if (Offers[Source] <> nil) and Offers[Source].Holds(Format) then
  begin
    Data := Offers[Source].DataOf(Format);
    Exit(True);
  end;
  if not IsConnected then
    Exit;
  Message := NewMessage(RequestAskData, 0);
  Message.Value := LongInt(Source);
  Message.Code := Format;
  SendRequest(Message, -1);
  Deadline := UptimeMilliseconds + DataReplyTimeout;
  repeat
    Now := UptimeMilliseconds;
    if Now >= Deadline then
      Exit;
    if not WaitForEvent(EventDataDelivered, Deadline - Now, Message) then
      Exit;
    Section := TakeMessageHandle(Message);
    { An answer that came too late for an earlier question is dropped. }
    if (LongWord(Message.Value) <> Source) or (Message.Code <> Format) then
    begin
      DropSection(Section);
      Continue;
    end;
    if ((Message.Flags and DataAvailable) = 0) or (Message.Width <= 0) then
    begin
      DropSection(Section);
      Exit(((Message.Flags and DataAvailable) <> 0) and (Message.Width = 0));
    end;
    Exit(ReadSection(Section, QWord(Message.Width), Data));
  until False;
end;

initialization
  DataRenderHandler := @AnswerRenderRequest;
finalization
  { What is on the clipboard stays there when the program ends. }
  GiveEveryFormat(DataSourceClipboard);
  ForgetOffer(DataSourceClipboard);
  ForgetOffer(DataSourceDrag);
end.
