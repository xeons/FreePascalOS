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
  The clipboard, and the data of the drag going on: offers of data in
  formats, from one program to the others.

  Each source (the clipboard, the drag) has at most one offer: the
  program that made it and the formats it has. A program that wants a
  format asks; if the server holds the bytes it sends them at once,
  otherwise it asks the offer's program for them (EventDataRender, once
  per format) and keeps the question until they come. What a program
  gives is copied and kept with the offer (at most MaximumDataBytes a
  format), so the clipboard still has it after the program ends;
  formats it never gave go with it then. A new offer replaces the old,
  whose program hears that the clipboard is no longer its own; programs
  watching the clipboard hear of every change.

  Bytes travel in sections both ways: the server maps what it is given
  and copies it out, and gives every program that asks a section of its
  own with a copy, so nobody can change what another reads.

  The drag requests (start, answers, the drop's end) go on to
  Server.DataDrag, which follows the pointer.
}
unit Server.DataOffers;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Protocol,
  Server.Clients;

{ Carries out Message if it is about the clipboard or a drag (Handle
  taken); False if it is not. }
function CarryOutDataRequest(Client: TClient; var Message: TWindowMessage; Handle: Int64): Boolean;
{ Client is going: its offers keep only what it gave, its questions and
  its watch go. }
procedure ForgetClientData(Client: TClient);
{ The program whose offer the drag carries, and the formats (Server.DataDrag). }
function DragOfferOwner: TClient;
function DragOfferFormats: LongWord;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Objects,
  Server.Windows,
  Server.DataDrag;

type
  TStoredFormat = record
    Data: TBytes;
    { The bytes are here (Data, possibly empty). }
    Held: Boolean;
    { Its program was asked for it, and has not answered yet. }
    Asked: Boolean;
  end;

  TDataStore = record
    { The program that offered (nil once it ended, or no offer). }
    Owner: TClient;
    { That program's number for the offer. }
    OwnerOfferNumber: LongWord;
    Formats: LongWord;
    Stored: array[1..DataFormatCount] of TStoredFormat;
  end;

  TPendingQuestion = record
    Client: TClient;
    Source: LongWord;
    Format: LongWord;
  end;

var
  Stores: array[DataSourceClipboard..DataSourceDrag] of TDataStore;
  Questions: array of TPendingQuestion;
  Watchers: array of TClient;
  ClipboardChanges: LongWord;

function EveryFormat: LongWord;
begin
  Result := (LongWord(1) shl DataFormatCount) - 1;
end;

function DragOfferOwner: TClient;
begin
  Result := Stores[DataSourceDrag].Owner;
end;

function DragOfferFormats: LongWord;
begin
  Result := Stores[DataSourceDrag].Formats;
end;

{ --- Sending data ---------------------------------------------------------------- }

procedure SendNoData(Client: TClient; Source, Format: LongWord);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(EventDataDelivered, 0);
  Message.Value := LongInt(Source);
  Message.Code := Format;
  SendToClient(Client, Message);
end;

{ Sends Client a section of its own with a copy of Data. }
procedure SendData(Client: TClient; Source, Format: LongWord; const Data: TBytes);
var
  Message: TWindowMessage;
  Section: Int64;
  Bytes: Pointer;
begin
  Message := NewMessage(EventDataDelivered, 0);
  Message.Value := LongInt(Source);
  Message.Code := Format;
  Message.Flags := DataAvailable;
  Message.Width := Length(Data);
  if Length(Data) = 0 then
  begin
    SendToClient(Client, Message);
    Exit;
  end;
  Section := CreateSection(Length(Data));
  if Section < 0 then
  begin
    SendNoData(Client, Source, Format);
    Exit;
  end;
  Bytes := MapSection(Section, 0, Length(Data));
  if Bytes = nil then
  begin
    CloseHandle(Section);
    SendNoData(Client, Source, Format);
    Exit;
  end;
  Move(Data[0], Bytes^, Length(Data));
  UnmapSection(Bytes);
  SendMessage(Client.Channel, @Message, SizeOf(Message), [Section]);
  CloseHandle(Section);
end;

{ The bytes a program gave in Section (closed here); False if they
  cannot be read. }
function ReadGivenSection(Section: Int64; Length: LongInt; out Data: TBytes): Boolean;
var
  Bytes: Pointer;
begin
  Data := nil;
  if Length = 0 then
  begin
    if Section >= 0 then
      CloseHandle(Section);
    Exit(True);
  end;
  Result := False;
  if Section < 0 then
    Exit;
  Bytes := MapSection(Section, 0, QWord(Length));
  if Bytes <> nil then
  begin
    SetLength(Data, Length);
    Move(Bytes^, Data[0], Length);
    UnmapSection(Bytes);
    Result := True;
  end;
  CloseHandle(Section);
end;

{ --- Questions ------------------------------------------------------------------- }

procedure AddQuestion(Client: TClient; Source, Format: LongWord);
var
  Question: TPendingQuestion;
begin
  Question.Client := Client;
  Question.Source := Source;
  Question.Format := Format;
  Insert(Question, Questions, Length(Questions));
end;

{ Answers every question about Source's Format (every format if Format
  is 0) with what the store holds, or nothing. }
procedure AnswerQuestions(Source, Format: LongWord);
var
  Index: LongInt;
  Question: TPendingQuestion;
begin
  Index := 0;
  while Index < Length(Questions) do
  begin
    Question := Questions[Index];
    if (Question.Source <> Source) or ((Format <> 0) and (Question.Format <> Format)) then
    begin
      Inc(Index);
      Continue;
    end;
    Delete(Questions, Index, 1);
    if Stores[Source].Stored[Question.Format].Held and
       ((Stores[Source].Formats and DataFormatBit(Question.Format)) <> 0) then
      SendData(Question.Client, Source, Question.Format, Stores[Source].Stored[Question.Format].Data)
    else
      SendNoData(Question.Client, Source, Question.Format);
  end;
end;

{ --- The clipboard's watchers ------------------------------------------------------ }

function IsWatching(Client: TClient): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to High(Watchers) do
    if Watchers[Index] = Client then
      Exit(True);
  Result := False;
end;

procedure SetWatching(Client: TClient; Watch: Boolean);
var
  Index: LongInt;
begin
  if Watch then
  begin
    if not IsWatching(Client) then
      Insert(Client, Watchers, Length(Watchers));
    Exit;
  end;
  for Index := High(Watchers) downto 0 do
    if Watchers[Index] = Client then
      Delete(Watchers, Index, 1);
end;

procedure SendClipboardFormats(Client: TClient; Kind: LongWord);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(Kind, 0);
  Message.Flags := Stores[DataSourceClipboard].Formats;
  Message.Code := Ord((Stores[DataSourceClipboard].Owner = Client) and (Client <> nil));
  Message.Value := LongInt(ClipboardChanges);
  SendToClient(Client, Message);
end;

procedure ClipboardChanged;
var
  Index: LongInt;
begin
  Inc(ClipboardChanges);
  for Index := 0 to High(Watchers) do
    SendClipboardFormats(Watchers[Index], EventClipboardChanged);
end;

{ --- Offers ------------------------------------------------------------------------ }

procedure ClearStore(Source: LongWord);
var
  Format: LongWord;
begin
  for Format := 1 to DataFormatCount do
  begin
    Stores[Source].Stored[Format].Data := nil;
    Stores[Source].Stored[Format].Held := False;
    Stores[Source].Stored[Format].Asked := False;
  end;
  Stores[Source].Formats := 0;
  Stores[Source].Owner := nil;
  Stores[Source].OwnerOfferNumber := 0;
end;

procedure TellClipboardLost(Client: TClient; OfferNumber: LongWord);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(EventClipboardLost, 0);
  Message.Code := OfferNumber;
  SendToClient(Client, Message);
end;

procedure TakeOffer(Client: TClient; Source, Formats, OfferNumber: LongWord);
var
  PreviousOwner: TClient;
  PreviousNumber: LongWord;
begin
  PreviousOwner := Stores[Source].Owner;
  PreviousNumber := Stores[Source].OwnerOfferNumber;
  { Questions about the old offer get nothing: it is gone. }
  Stores[Source].Formats := 0;
  AnswerQuestions(Source, 0);
  ClearStore(Source);
  Formats := Formats and EveryFormat;
  if Formats <> 0 then
  begin
    Stores[Source].Owner := Client;
    Stores[Source].OwnerOfferNumber := OfferNumber;
    Stores[Source].Formats := Formats;
  end;
  if Source <> DataSourceClipboard then
    Exit;
  if (PreviousOwner <> nil) and (PreviousOwner <> Client) then
    TellClipboardLost(PreviousOwner, PreviousNumber);
  ClipboardChanged;
end;

{ Drops Format from Source's offer (it cannot be had); questions about
  it get nothing. }
procedure DropFormat(Source, Format: LongWord);
begin
  Stores[Source].Formats := Stores[Source].Formats and not DataFormatBit(Format);
  Stores[Source].Stored[Format].Data := nil;
  Stores[Source].Stored[Format].Held := False;
  Stores[Source].Stored[Format].Asked := False;
  AnswerQuestions(Source, Format);
  if Stores[Source].Formats = 0 then
    Stores[Source].Owner := nil;
  if Source = DataSourceClipboard then
    ClipboardChanged;
end;

function KnownFormat(Format: LongWord): Boolean;
begin
  Result := (Format >= 1) and (Format <= DataFormatCount);
end;

procedure TakeProvidedData(Client: TClient; const Message: TWindowMessage; Handle: Int64);
var
  Source: LongWord;
  Format: LongWord;
  Data: TBytes;
begin
  Source := LongWord(Message.Value);
  Format := Message.Code;
  if not KnownFormat(Format) or (Stores[Source].Owner <> Client) or
     ((Stores[Source].Formats and DataFormatBit(Format)) = 0) then
  begin
    if Handle >= 0 then
      CloseHandle(Handle);
    Exit;
  end;
  if ((Message.Flags and DataAvailable) = 0) or (Message.Width < 0) or (Message.Width > MaximumDataBytes) or
     not ReadGivenSection(Handle, Message.Width, Data) then
  begin
    DropFormat(Source, Format);
    Exit;
  end;
  Stores[Source].Stored[Format].Data := Data;
  Stores[Source].Stored[Format].Held := True;
  Stores[Source].Stored[Format].Asked := False;
  AnswerQuestions(Source, Format);
end;

procedure AskForData(Client: TClient; Source, Format: LongWord);
var
  Message: TWindowMessage;
begin
  if not KnownFormat(Format) or ((Stores[Source].Formats and DataFormatBit(Format)) = 0) then
  begin
    SendNoData(Client, Source, Format);
    Exit;
  end;
  if Stores[Source].Stored[Format].Held then
  begin
    SendData(Client, Source, Format, Stores[Source].Stored[Format].Data);
    Exit;
  end;
  if Stores[Source].Owner = nil then
  begin
    SendNoData(Client, Source, Format);
    Exit;
  end;
  AddQuestion(Client, Source, Format);
  if Stores[Source].Stored[Format].Asked then
    Exit;
  Stores[Source].Stored[Format].Asked := True;
  Message := NewMessage(EventDataRender, 0);
  Message.Value := LongInt(Source);
  Message.Code := Format;
  SendToClient(Stores[Source].Owner, Message);
end;

procedure ForgetClientData(Client: TClient);
var
  Source: LongWord;
  Format: LongWord;
  Index: LongInt;
  Before: LongWord;
begin
  SetWatching(Client, False);
  for Index := High(Questions) downto 0 do
    if Questions[Index].Client = Client then
      Delete(Questions, Index, 1);
  for Source := DataSourceClipboard to DataSourceDrag do
  begin
    if Stores[Source].Owner <> Client then
      Continue;
    Stores[Source].Owner := nil;
    Before := Stores[Source].Formats;
    { What it gave stays; what it did not can no longer be had. }
    for Format := 1 to DataFormatCount do
      if not Stores[Source].Stored[Format].Held then
      begin
        Stores[Source].Formats := Stores[Source].Formats and not DataFormatBit(Format);
        Stores[Source].Stored[Format].Asked := False;
      end;
    AnswerQuestions(Source, 0);
    if (Source = DataSourceClipboard) and (Stores[Source].Formats <> Before) then
      ClipboardChanged;
  end;
end;

{ --- Requests ------------------------------------------------------------------------- }

{ The window Message names, if it is Client's. }
function ClientWindow(Client: TClient; const Message: TWindowMessage): TServerWindow;
begin
  Result := FindWindow(Message.Window);
  if (Result <> nil) and (Result.Client <> Client) then
    Result := nil;
end;

function IsDataRequest(Kind: LongWord): Boolean;
begin
  Result := (Kind >= RequestOfferData) and (Kind <= RequestFinishDrop);
end;

function CarryOutDataRequest(Client: TClient; var Message: TWindowMessage; Handle: Int64): Boolean;
var
  Source: LongWord;
begin
  Result := IsDataRequest(Message.Kind);
  if not Result then
    Exit;
  Source := LongWord(Message.Value);
  if Message.Kind = RequestProvideData then
  begin
    if Source <= DataSourceDrag then
      TakeProvidedData(Client, Message, Handle)
    else if Handle >= 0 then
      CloseHandle(Handle);
    Exit;
  end;
  if Handle >= 0 then
    CloseHandle(Handle);
  case Message.Kind of
    RequestOfferData:
      if Source <= DataSourceDrag then
        TakeOffer(Client, Source, Message.Flags, Message.Code);
    RequestAskData:
      if Source <= DataSourceDrag then
        AskForData(Client, Source, Message.Code)
      else
        SendNoData(Client, Source, Message.Code);
    RequestWatchClipboard:
      SetWatching(Client, Message.Value <> 0);
    RequestDescribeClipboard:
      SendClipboardFormats(Client, EventClipboardFormats);
    RequestStartDrag:
      StartDataDrag(Client, ClientWindow(Client, Message), Message.Code, MessageText(Message));
    RequestAnswerDrag:
      TakeDragAnswer(ClientWindow(Client, Message), LongWord(Message.Value), Message.Code);
    RequestFinishDrop:
      TakeDropFinish(ClientWindow(Client, Message), LongWord(Message.Value), Message.Code);
  end;
end;

end.
