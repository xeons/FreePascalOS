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
  Tasks waiting for a time ("run steps after a timeout", HTML Standard
  section 8.6): a binary heap ordered by due time and then by the order
  they were scheduled in, so two timers due at the same moment run in
  the order they were set, as the standard requires. Cancelling takes
  the task out of the live set at once (it is freed then) and leaves
  its heap slot to be skipped when it comes up.
}
unit Web.EventLoop.DelayedTasks;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.IdMaps,
  Web.EventLoop.Tasks;

type
  TDelayedTaskEntry = record
    Due: Double;
    Handle: QWord;
    Task: TWebTask;
  end;

  TDelayedTaskList = class
  private
    FHeap: array of TDelayedTaskEntry;
    FCount: Integer;
    FLive: TIdMap;
    FNextHandle: QWord;
    function Earlier(constref First, Second: TDelayedTaskEntry): Boolean;
    procedure SiftUp(Index: Integer);
    procedure SiftDown(Index: Integer);
    procedure RemoveTop;
    procedure DropCanceledTop;
    procedure Compact;
  public
    constructor Create;
    destructor Destroy; override;
    { Task becomes due at Due (milliseconds); the handle cancels it. }
    function Add(Task: TWebTask; Due: Double): QWord;
    { Frees the task if it has not become due yet; False otherwise. }
    function Cancel(Handle: QWord): Boolean;
    { The earliest due time; False when nothing waits. }
    function NextDue(out Due: Double): Boolean;
    { The earliest task due at or before Now (taken out), or nil. }
    function TakeDue(Now: Double): TWebTask;
    { Frees the waiting tasks of Group. }
    procedure Discard(Group: Pointer);
    function Count: Integer;
  end;

implementation

constructor TDelayedTaskList.Create;
begin
  inherited Create;
  FLive := TIdMap.Create;
end;

destructor TDelayedTaskList.Destroy;
var
  Task: TObject;
begin
  for Task in FLive.Values do
    Task.Free;
  FLive.Free;
  inherited Destroy;
end;

function TDelayedTaskList.Earlier(constref First, Second: TDelayedTaskEntry): Boolean;
begin
  if First.Due <> Second.Due then
    Exit(First.Due < Second.Due);
  Result := First.Handle < Second.Handle;
end;

procedure TDelayedTaskList.SiftUp(Index: Integer);
var
  Parent: Integer;
  Swap: TDelayedTaskEntry;
begin
  while Index > 0 do
  begin
    Parent := (Index - 1) div 2;
    if not Earlier(FHeap[Index], FHeap[Parent]) then
      Break;
    Swap := FHeap[Index];
    FHeap[Index] := FHeap[Parent];
    FHeap[Parent] := Swap;
    Index := Parent;
  end;
end;

procedure TDelayedTaskList.SiftDown(Index: Integer);
var
  Child, Smallest: Integer;
  Swap: TDelayedTaskEntry;
begin
  while True do
  begin
    Smallest := Index;
    Child := Index * 2 + 1;
    if (Child < FCount) and Earlier(FHeap[Child], FHeap[Smallest]) then
      Smallest := Child;
    Inc(Child);
    if (Child < FCount) and Earlier(FHeap[Child], FHeap[Smallest]) then
      Smallest := Child;
    if Smallest = Index then
      Break;
    Swap := FHeap[Index];
    FHeap[Index] := FHeap[Smallest];
    FHeap[Smallest] := Swap;
    Index := Smallest;
  end;
end;

procedure TDelayedTaskList.RemoveTop;
begin
  Dec(FCount);
  FHeap[0] := FHeap[FCount];
  FHeap[FCount].Task := nil;
  if FCount > 0 then
    SiftDown(0);
end;

procedure TDelayedTaskList.DropCanceledTop;
begin
  while (FCount > 0) and not FLive.ContainsKey(FHeap[0].Handle) do
    RemoveTop;
end;

function TDelayedTaskList.Add(Task: TWebTask; Due: Double): QWord;
begin
  Inc(FNextHandle);
  Result := FNextHandle;
  if FCount = Length(FHeap) then
    SetLength(FHeap, FCount * 2 + 8);
  FHeap[FCount].Due := Due;
  FHeap[FCount].Handle := Result;
  FHeap[FCount].Task := Task;
  Inc(FCount);
  SiftUp(FCount - 1);
  FLive.Add(Result, Task);
end;

function TDelayedTaskList.Cancel(Handle: QWord): Boolean;
var
  Task: TObject;
begin
  Result := FLive.TryGetValue(Handle, Task);
  if not Result then
    Exit;
  FLive.Remove(Handle);
  Task.Free;
  DropCanceledTop;
  if FCount > 2 * FLive.Count + 64 then
    Compact;
end;

{ Cancelled slots deep in the heap are dropped when they outnumber the
  live ones, so setting and clearing timers does not grow the heap. }
procedure TDelayedTaskList.Compact;
var
  Source, Kept, Index: Integer;
begin
  Kept := 0;
  for Source := 0 to FCount - 1 do
    if FLive.ContainsKey(FHeap[Source].Handle) then
    begin
      FHeap[Kept] := FHeap[Source];
      Inc(Kept);
    end;
  for Index := Kept to FCount - 1 do
    FHeap[Index].Task := nil;
  FCount := Kept;
  Index := FCount div 2;
  while Index > 0 do
  begin
    Dec(Index);
    SiftDown(Index);
  end;
end;

function TDelayedTaskList.NextDue(out Due: Double): Boolean;
begin
  DropCanceledTop;
  Result := FCount > 0;
  if Result then
    Due := FHeap[0].Due
  else
    Due := 0;
end;

function TDelayedTaskList.TakeDue(Now: Double): TWebTask;
begin
  Result := nil;
  DropCanceledTop;
  if (FCount = 0) or (FHeap[0].Due > Now) then
    Exit;
  Result := FHeap[0].Task;
  FLive.Remove(FHeap[0].Handle);
  RemoveTop;
end;

procedure TDelayedTaskList.Discard(Group: Pointer);
var
  Handles: TIdArray;
  Task: TObject;
  Index: Integer;
begin
  Handles := FLive.Keys;
  for Index := 0 to High(Handles) do
    if FLive.TryGetValue(Handles[Index], Task) and (TWebTask(Task).Group = Group) then
      Cancel(Handles[Index]);
end;

function TDelayedTaskList.Count: Integer;
begin
  Result := FLive.Count;
end;

end.
