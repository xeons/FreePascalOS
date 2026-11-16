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
  Dragging data from one window to another (of any programs).

  A program starts a drag from its window while button 1 is held
  (RequestStartDrag), its data offered just before (Server.DataOffers).
  From then on the pointer belongs to the drag: no window gets pointer
  events or keys. The window under the pointer (its client area, enabled)
  hears the drag come in, move over it and go out (EventDragEnter,
  EventDragOver, EventDragLeave); each answers what a drop there would
  do, which shows beside the pointer (Server.DragFeedback). Ctrl, Shift
  and Alt changing tell it again; Escape cancels. When button 1 is let
  go the window under the pointer hears EventDrop and says what it did
  (RequestFinishDrop), which the window the drag started from hears
  (EventDragFinished); with no window there, or a cancelled drag, it
  hears that nothing was done.

  While the screen is locked (Server.ScreenLock) no drag starts, and
  locking cancels one: only the lock screen's windows are ever under the
  pointer (WindowAt).

  A program that starts a drag a moment after the button was let go
  (it saw the pointer move with it held, the release still on its way)
  gets the drop where the pointer is.
}
unit Server.DataDrag;

{$mode objfpc}
{$H+}

interface

uses
  Server.Windows,
  Server.Clients;

{ True while a drag follows the pointer. }
function DataDragActive: Boolean;
{ Starts a drag from Window (Client's; nil refuses it) of the drag offer,
  allowing AllowedEffects; Description shows beside the pointer. }
procedure StartDataDrag(Client: TClient; Window: TServerWindow; AllowedEffects: LongWord; const Description: string);
{ What the window under the drag says a drop would do. }
procedure TakeDragAnswer(Window: TServerWindow; Number, Effect: LongWord);
{ What the window dropped on did. }
procedure TakeDropFinish(Window: TServerWindow; Number, Effect: LongWord);
{ Ends the drag with nothing dropped (Escape, or the screen locked). }
procedure CancelDataDrag;
{ The pointer moved (Modifiers: the keyboard's). }
procedure DataDragPointerMoved(Modifiers: LongWord);
{ Button 1 was let go: the drop. }
procedure FinishDataDrag(Modifiers: LongWord);
{ A key while dragging: Escape cancels, a modifier changing tells the
  window under the pointer again. }
procedure DataDragKey(Code: LongWord; Pressed: Boolean; Modifiers: LongWord);
{ The window is going: the drag forgets it (cancelled, if it started
  there). }
procedure ForgetWindowInDataDrag(Window: TServerWindow);

implementation

uses
  Drawing.Rectangles,
  Windowing.Protocol,
  Server.Frames,
  Server.Cursor,
  Server.Actions,
  Server.Input,
  Server.DataOffers,
  Server.DragFeedback,
  Server.ScreenLock;

const
  ScanEscape = $01;

var
  Active: Boolean;
  { The drag's number: answers about an older drag are ignored. }
  Number: LongWord;
  Source: TServerWindow;
  AllowedEffects: LongWord;
  Formats: LongWord;
  Description: string;
  { The window under the pointer, and what it said a drop would do. }
  Target: TServerWindow;
  TargetEffect: LongWord;
  LastModifiers: LongWord;
  { A drop waiting for its window to say what it did. }
  DropPending: Boolean;
  DropNumber: LongWord;
  DropTarget: TServerWindow;
  DropSource: TServerWindow;

function DataDragActive: Boolean;
begin
  Result := Active;
end;

procedure TellSource(Window: TServerWindow; DragNumber, Effect: LongWord);
var
  Message: TWindowMessage;
begin
  if Window = nil then
    Exit;
  Message := NewMessage(EventDragFinished, Window.Id);
  Message.Value := LongInt(DragNumber);
  Message.Code := Effect;
  SendToProgram(Window, Message);
end;

procedure SendDragEvent(Window: TServerWindow; Kind: LongWord);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(Kind, Window.Id);
  Message.Value := LongInt(Number);
  if Kind <> EventDragLeave then
  begin
    Message.Left := PointerX - Window.ClientLeft;
    Message.Top := PointerY - Window.ClientTop;
    Message.Flags := Formats;
    Message.Code := AllowedEffects;
    Message.Modifiers := LastModifiers;
    SetMessageText(Message, Description);
  end;
  SendToProgram(Window, Message);
end;

{ The window whose client area the pointer is over, if it takes input. }
function WindowUnderPointer: TServerWindow;
begin
  Result := WindowAt(PointerX, PointerY);
  if (Result <> nil) and ((HitTest(Result, PointerX, PointerY) <> HitClient) or Result.Disabled) then
    Result := nil;
end;

{ Finds the window under the pointer and tells it (and the one it left). }
procedure FollowPointer;
var
  Under: TServerWindow;
begin
  Under := WindowUnderPointer;
  if Under <> Target then
  begin
    if Target <> nil then
      SendDragEvent(Target, EventDragLeave);
    Target := Under;
    TargetEffect := 0;
    if Target <> nil then
      SendDragEvent(Target, EventDragEnter);
  end
  else if Target <> nil then
    SendDragEvent(Target, EventDragOver);
  ShowDragFeedback(TargetEffect, Description);
end;

{ Ends the drag (the pointer is the windows' again). }
procedure EndDrag;
begin
  Active := False;
  Target := nil;
  Source := nil;
  HideDragFeedback;
end;

{ A drop still waiting for its answer ends with nothing done. }
procedure AbandonPendingDrop;
begin
  if not DropPending then
    Exit;
  DropPending := False;
  TellSource(DropSource, DropNumber, 0);
  DropTarget := nil;
  DropSource := nil;
end;

procedure CancelDataDrag;
var
  Window: TServerWindow;
begin
  if not Active then
    Exit;
  if Target <> nil then
    SendDragEvent(Target, EventDragLeave);
  Window := Source;
  EndDrag;
  TellSource(Window, Number, 0);
end;

procedure StartDataDrag(Client: TClient; Window: TServerWindow; AllowedEffects: LongWord; const Description: string);
var
  Message: TWindowMessage;
begin
  if (Window = nil) or (DragOfferOwner <> Client) or (DragOfferFormats = 0) or Active or (AllowedEffects = 0) or
     not WindowUsable(Window) then
  begin
    if Window <> nil then
    begin
      Message := NewMessage(EventDragFinished, Window.Id);
      SendToProgram(Window, Message);
    end;
    Exit;
  end;
  AbandonPendingDrop;
  Inc(Number);
  Active := True;
  Source := Window;
  Server.DataDrag.AllowedEffects := AllowedEffects;
  Server.DataDrag.Description := Description;
  Formats := DragOfferFormats;
  Target := nil;
  TargetEffect := 0;
  LastModifiers := CurrentKeyboardModifiers;
  ReleasePointerForDrag;
  FollowPointer;
  { Let go already: dropped where the pointer is. }
  if not LeftButtonHeld then
    FinishDataDrag(LastModifiers);
end;

procedure TakeDragAnswer(Window: TServerWindow; Number, Effect: LongWord);
begin
  if not Active or (Window = nil) or (Window <> Target) or (Number <> Server.DataDrag.Number) then
    Exit;
  TargetEffect := Effect and AllowedEffects;
  ShowDragFeedback(TargetEffect, Description);
end;

procedure TakeDropFinish(Window: TServerWindow; Number, Effect: LongWord);
begin
  if not DropPending or (Window = nil) or (Window <> DropTarget) or (Number <> DropNumber) then
    Exit;
  DropPending := False;
  TellSource(DropSource, DropNumber, Effect and AllowedEffects);
  DropTarget := nil;
  DropSource := nil;
end;

procedure DataDragPointerMoved(Modifiers: LongWord);
begin
  if not Active then
    Exit;
  LastModifiers := Modifiers;
  FollowPointer;
end;

procedure FinishDataDrag(Modifiers: LongWord);
var
  Window: TServerWindow;
begin
  if not Active then
    Exit;
  LastModifiers := Modifiers;
  Window := WindowUnderPointer;
  if Window <> Target then
    FollowPointer;
  if Target = nil then
  begin
    Window := Source;
    EndDrag;
    TellSource(Window, Number, 0);
    Exit;
  end;
  { The window decides now, wherever its answers had got to. }
  SendDragEvent(Target, EventDrop);
  DropPending := True;
  DropNumber := Number;
  DropTarget := Target;
  DropSource := Source;
  EndDrag;
end;

procedure DataDragKey(Code: LongWord; Pressed: Boolean; Modifiers: LongWord);
begin
  if not Active then
    Exit;
  if Pressed and (Code = ScanEscape) then
  begin
    CancelDataDrag;
    Exit;
  end;
  if Modifiers = LastModifiers then
    Exit;
  LastModifiers := Modifiers;
  if Target <> nil then
    SendDragEvent(Target, EventDragOver);
end;

procedure ForgetWindowInDataDrag(Window: TServerWindow);
begin
  if Window = nil then
    Exit;
  if DropPending and (Window = DropSource) then
    DropSource := nil;
  if DropPending and (Window = DropTarget) then
  begin
    DropTarget := nil;
    AbandonPendingDrop;
  end;
  if not Active then
    Exit;
  if Window = Target then
  begin
    Target := nil;
    TargetEffect := 0;
    ShowDragFeedback(0, Description);
  end;
  if Window = Source then
  begin
    { Nobody to tell what a drop did: the drag ends. }
    if Target <> nil then
      SendDragEvent(Target, EventDragLeave);
    EndDrag;
  end;
end;

end.
