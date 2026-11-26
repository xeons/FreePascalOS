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
  Finding where a thrown exception is caught in a frame, and delivering
  it there (the interpreter does the unwinding of frames).

  The innermost handler whose code range holds the throwing instruction
  is asked first; a handler that does not catch passes the exception to
  the handler around it (Outer), a delegate to its target's handler, and
  -1 means the frame's caller. Tags match by identity (the instance's tag
  object), catch_all matches everything. Delivery writes the payload to
  the clause's slots, then the exception itself for catch_ref and
  catch_all_ref, and into the legacy catch's hidden slot for rethrow.
}
unit Wasm.Unwinding;

{$mode objfpc}
{$H+}
{$R-}
{$Q-}

interface

uses
  Wasm.Code,
  Wasm.GcHeap,
  Wasm.Runtime;

{ The clause of Code that catches Exception thrown at instruction
  Position, or -1. }
function FindCatchClause(Code: TCompiledFunction; Position: Integer; Instance: TWasmModuleInstance;
  Exception: PWasmGcObject): Integer;
{ Writes the exception to the clause's slots; the code index to go on. }
function DeliverException(Code: TCompiledFunction; Clause: Integer; Exception: PWasmGcObject; Slots: PQWord): Integer;
{ Raises the EWasmException for an exception no frame caught. }
procedure RaiseUncaught(Store: TWasmStore; Exception: PWasmGcObject);

implementation

uses
  Wasm.Exceptions;

function InnermostHandler(Code: TCompiledFunction; Position: Integer): Integer;
var
  Index: Integer;
  Size, Best: Int32;
begin
  Result := -1;
  Best := High(Int32);
  for Index := 0 to High(Code.Handlers) do
    with Code.Handlers[Index] do
      if (Position >= Start) and (Position < Limit) then
      begin
        Size := Limit - Start;
        if Size <= Best then
        begin
          Best := Size;
          Result := Index;
        end;
      end;
end;

function FindCatchClause(Code: TCompiledFunction; Position: Integer; Instance: TWasmModuleInstance;
  Exception: PWasmGcObject): Integer;
var
  Handler, Clause, Guard: Integer;
  Tag: TWasmTag;
begin
  Result := -1;
  if Length(Code.Handlers) = 0 then
    Exit;
  Tag := TWasmTag(Exception^.Descriptor);
  Handler := InnermostHandler(Code, Position);
  Guard := 0;
  while (Handler >= 0) and (Guard <= Length(Code.Handlers)) do
  begin
    with Code.Handlers[Handler] do
    begin
      if Kind = hkDelegate then
      begin
        Handler := DelegateTarget;
        Inc(Guard);
        Continue;
      end;
      for Clause := FirstClause to FirstClause + ClauseCount - 1 do
        if (Code.Clauses[Clause].Tag < 0) or (Instance.Tags[Code.Clauses[Clause].Tag] = Tag) then
          Exit(Clause);
      Handler := Outer;
    end;
    Inc(Guard);
  end;
end;

function DeliverException(Code: TCompiledFunction; Clause: Integer; Exception: PWasmGcObject; Slots: PQWord): Integer;
var
  Payload: PQWord;
  Count: Integer;
begin
  with Code.Clauses[Clause] do
  begin
    Count := 0;
    if Tag >= 0 then
    begin
      Count := Exception^.Length;
      Payload := PQWord(ObjectPayload(Exception));
      if Count > 0 then
        Move(Payload^, Slots[Destination], Count * SizeOf(QWord));
    end;
    if PushesException then
      Slots[Destination + Count] := QWord(PtrUInt(Exception));
    if ExceptionSlot >= 0 then
      Slots[ExceptionSlot] := QWord(PtrUInt(Exception));
    Result := Code.BranchTargets[TargetEntry];
  end;
end;

procedure RaiseUncaught(Store: TWasmStore; Exception: PWasmGcObject);
begin
  Store.Heap.Expose(Exception);
  raise EWasmException.CreateFor(Store, Exception);
end;

end.
