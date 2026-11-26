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
  The web view's clipboard events (Clipboard API and events 5.1): copy,
  cut and paste fired at the focused element (the body when nothing is
  focused) before the view copies, cuts or pastes. copy and cut carry
  an empty DataTransfer the page may write; when a listener cancels the
  event, what it put there as text/plain goes to the clipboard instead
  of the selection (and nothing is cut). paste carries the clipboard's
  text, read-only; a cancelled paste inserts nothing.
}
unit WebView.ClipboardEvents;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom;

type
  TClipboardOutcome = record
    { No listener cancelled the event: the view does what it was asked. }
    Proceed: Boolean;
    { Cancelled with text/plain data for the clipboard (copy, cut). }
    HasData: Boolean;
    Data: string;
  end;

{ copy or cut at Target. }
function FireCopyEvent(Target: TNode; const EventType: string): TClipboardOutcome;
{ paste at Target with the clipboard's text. }
function FirePasteEvent(Target: TNode; const ClipboardText: string): TClipboardOutcome;
{ The target of a clipboard event: the focused element, else the body
  (else the document element). }
function ClipboardEventTarget(Document: TDocument): TNode;

implementation

uses
  Web.Dom.Events,
  Web.Dom.DataTransfer;

function ClipboardEventTarget(Document: TDocument): TNode;
begin
  Result := nil;
  if Document = nil then
    Exit;
  if Document.FocusedElement <> nil then
    Exit(Document.FocusedElement);
  Result := Document.Body;
  if Result = nil then
    Result := Document.DocumentElement;
end;

function Dispatch(Target: TNode; const EventType: string; Mode: TDataTransferMode;
  const ClipboardText: string): TClipboardOutcome;
var
  Event: TClipboardEvent;
  Data: TDataTransfer;
begin
  Result := Default(TClipboardOutcome);
  Result.Proceed := True;
  if (Target = nil) or not Target.IsConnected then
    Exit;
  Data := TDataTransfer.Create;
  if EventType = 'paste' then
    Data.SetData('text/plain', ClipboardText);
  Data.Mode := Mode;
  Event := TClipboardEvent.Create(EventType, True, True);
  Target.Retain;
  try
    Event.IsTrusted := True;
    Event.Composed := True;
    Event.ClipboardData := Data;
    Event.OwnsData := True;
    Result.Proceed := Target.DispatchEvent(Event);
    { After the dispatch the data store is protected (a kept event
      gives nothing). }
    Data.Mode := DataTransferReadWrite;
    if not Result.Proceed and (EventType <> 'paste') then
    begin
      Result.HasData := Data.HasData;
      Result.Data := Data.GetData('text/plain');
    end;
    Data.Mode := DataTransferProtected;
  finally
    Target.Release;
    Event.Release;
  end;
end;

function FireCopyEvent(Target: TNode; const EventType: string): TClipboardOutcome;
begin
  Result := Dispatch(Target, EventType, DataTransferReadWrite, '');
end;

function FirePasteEvent(Target: TNode; const ClipboardText: string): TClipboardOutcome;
begin
  Result := Dispatch(Target, 'paste', DataTransferReadOnly, ClipboardText);
end;

end.
