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
  Drag and drop between windows, of any programs.

  A window starts a drag while button 1 is held on it (StartDrag): its
  data as a TDataOffer (Windowing.DataTransfer), every format given to
  the display server at once, the effects a drop may have (copy, move,
  link: DropEffect*) and a few words for beside the pointer. The server
  follows the pointer from then on and tells the windows under it
  (TWindow.DragOver, DragLeave, Drop: Windowing.Windows turns the
  events into a TDragEvent and sends the answers); the window it
  started from hears what the drop did (TWindow.DragFinished), after
  which the data is forgotten. A window a drag is over reads its data
  with ReadDragData.
}
unit Windowing.DragAndDrop;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Windowing.Protocol,
  Windowing.DataTransfer;

type
  TDragEvent = record
    { The pointer, in the window's surface pixels. }
    X: LongInt;
    Y: LongInt;
    { What the drag carries (DataFormatBit of each). }
    Formats: LongWord;
    { DropEffect*: those the drag allows; in Drop, the one chosen. }
    AllowedEffects: LongWord;
    Effect: LongWord;
    Modifiers: LongWord;
    { The server's number for the drag. }
    Number: LongWord;
    { What is dragged, in a few words. }
    Description: string;
    { The pointer just came into the window. }
    Entered: Boolean;
  end;

{ Starts a drag from window WindowId of Offer (taken), allowing
  AllowedEffects; Description shows beside the pointer. }
procedure StartDrag(WindowId: LongWord; Offer: TDataOffer; AllowedEffects: LongWord; const Description: string);
{ True while a drag this program started goes on. }
function OwnDragGoingOn: Boolean;
{ The drag's Format (for a window it is over, or dropped on). }
function ReadDragData(Format: LongWord; out Data: TBytes): Boolean;
function ReadDragText(out Text: string): Boolean;
{ What a drag event says. }
function DragEventFrom(const Message: TWindowMessage): TDragEvent;
{ Effect if it is allowed, else none (0). }
function AllowedEffect(Effect, Allowed: LongWord): LongWord;
{ Tells the server what a drop on window WindowId would do, and what
  the drop did. }
procedure AnswerDrag(WindowId, Number, Effect: LongWord);
procedure FinishDrop(WindowId, Number, Effect: LongWord);
{ This program's drag is over: its data is forgotten. }
procedure ForgetOwnDrag;

implementation

uses
  Windowing.Connection;

procedure StartDrag(WindowId: LongWord; Offer: TDataOffer; AllowedEffects: LongWord; const Description: string);
var
  Message: TWindowMessage;
begin
  OfferData(DataSourceDrag, Offer);
  { Given at once: the windows under the pointer read it while this
    program may be busy. }
  GiveEveryFormat(DataSourceDrag);
  Message := NewMessage(RequestStartDrag, WindowId);
  Message.Code := AllowedEffects;
  SetMessageText(Message, Description);
  SendRequest(Message, -1);
end;

function OwnDragGoingOn: Boolean;
begin
  Result := CurrentOffer(DataSourceDrag) <> nil;
end;

function ReadDragData(Format: LongWord; out Data: TBytes): Boolean;
begin
  Result := AskData(DataSourceDrag, Format, Data);
end;

function ReadDragText(out Text: string): Boolean;
var
  Data: TBytes;
begin
  Result := ReadDragData(DataFormatText, Data);
  Text := BytesToText(Data);
end;

function DragEventFrom(const Message: TWindowMessage): TDragEvent;
begin
  Result.X := Message.Left;
  Result.Y := Message.Top;
  Result.Formats := Message.Flags;
  Result.AllowedEffects := Message.Code;
  Result.Effect := 0;
  Result.Modifiers := Message.Modifiers;
  Result.Number := LongWord(Message.Value);
  Result.Description := MessageText(Message);
  Result.Entered := Message.Kind = EventDragEnter;
end;

function AllowedEffect(Effect, Allowed: LongWord): LongWord;
begin
  if (Effect and Allowed) <> 0 then
    Result := Effect and Allowed
  else
    Result := 0;
end;

procedure SendDragAnswer(Kind, WindowId, Number, Effect: LongWord);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(Kind, WindowId);
  Message.Value := LongInt(Number);
  Message.Code := Effect;
  SendRequest(Message, -1);
end;

procedure AnswerDrag(WindowId, Number, Effect: LongWord);
begin
  SendDragAnswer(RequestAnswerDrag, WindowId, Number, Effect);
end;

procedure FinishDrop(WindowId, Number, Effect: LongWord);
begin
  SendDragAnswer(RequestFinishDrop, WindowId, Number, Effect);
end;

procedure ForgetOwnDrag;
begin
  ForgetOffer(DataSourceDrag);
end;

end.
