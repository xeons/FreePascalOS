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
  Tasks of the event loop (HTML Standard section 8.1.7): a task is an
  object with a Run method, the task source it was queued on, and a
  group (the document or window it belongs to) so that the tasks of a
  document that goes away can be dropped together.

  TMethodTask runs a method; TDataTask runs a method with an object it
  owns (freed after the run, or when the task is dropped unrun), which
  is how network threads hand their data to the page thread.
}
unit Web.EventLoop.Tasks;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  { The task sources of the standard that the engine uses. The user
    interaction source is served first; the others oldest task first. }
  TTaskSource = (
    TaskSourceUserInteraction,
    TaskSourceDomManipulation,
    TaskSourceNetworking,
    TaskSourceNavigation,
    TaskSourceHistoryTraversal,
    TaskSourceTimer,
    TaskSourcePostedMessage,
    TaskSourceRendering);

  TWebTask = class
  private
    FSource: TTaskSource;
    FGroup: Pointer;
    FSequence: QWord;
    FTimerNestingLevel: Integer;
  public
    procedure Run; virtual; abstract;
    property Source: TTaskSource read FSource write FSource;
    { What the task belongs to (a document, a window); nil: nothing. }
    property Group: Pointer read FGroup write FGroup;
    { Set when queued: the order tasks were queued in. }
    property Sequence: QWord read FSequence write FSequence;
    { The timer nesting level of a timer's task (setTimeout clamping). }
    property TimerNestingLevel: Integer read FTimerNestingLevel write FTimerNestingLevel;
  end;

  TWebTaskArray = array of TWebTask;

  TTaskMethod = procedure of object;
  TTaskDataMethod = procedure(Data: TObject) of object;

  TMethodTask = class(TWebTask)
  private
    FMethod: TTaskMethod;
  public
    constructor Create(Method: TTaskMethod);
    procedure Run; override;
  end;

  TDataTask = class(TWebTask)
  private
    FMethod: TTaskDataMethod;
    FData: TObject;
  public
    { Data is owned by the task. }
    constructor Create(Method: TTaskDataMethod; Data: TObject);
    destructor Destroy; override;
    procedure Run; override;
    property Data: TObject read FData;
  end;

  { A first-in first-out queue of tasks (one task source's queue). }
  TTaskQueue = class
  private
    FItems: TWebTaskArray;
    FHead: Integer;
    FCount: Integer;
    function GetItem(Index: Integer): TWebTask;
  public
    destructor Destroy; override;
    procedure Push(Task: TWebTask);
    function Peek: TWebTask;
    function Pop: TWebTask;
    { Frees the tasks of Group (all when Group is nil and All). }
    procedure Discard(Group: Pointer; All: Boolean = False);
    property Count: Integer read FCount;
    property Items[Index: Integer]: TWebTask read GetItem;
  end;

implementation

constructor TMethodTask.Create(Method: TTaskMethod);
begin
  inherited Create;
  FMethod := Method;
end;

procedure TMethodTask.Run;
begin
  if Assigned(FMethod) then
    FMethod();
end;

constructor TDataTask.Create(Method: TTaskDataMethod; Data: TObject);
begin
  inherited Create;
  FMethod := Method;
  FData := Data;
end;

destructor TDataTask.Destroy;
begin
  FData.Free;
  inherited Destroy;
end;

procedure TDataTask.Run;
begin
  if Assigned(FMethod) then
    FMethod(FData);
end;

destructor TTaskQueue.Destroy;
begin
  Discard(nil, True);
  inherited Destroy;
end;

function TTaskQueue.GetItem(Index: Integer): TWebTask;
begin
  Result := FItems[(FHead + Index) mod Length(FItems)];
end;

procedure TTaskQueue.Push(Task: TWebTask);
var
  Grown: TWebTaskArray;
  Index: Integer;
begin
  if FCount = Length(FItems) then
  begin
    Grown := nil;
    SetLength(Grown, FCount * 2 + 8);
    for Index := 0 to FCount - 1 do
      Grown[Index] := GetItem(Index);
    FItems := Grown;
    FHead := 0;
  end;
  FItems[(FHead + FCount) mod Length(FItems)] := Task;
  Inc(FCount);
end;

function TTaskQueue.Peek: TWebTask;
begin
  if FCount = 0 then
    Exit(nil);
  Result := FItems[FHead];
end;

function TTaskQueue.Pop: TWebTask;
begin
  if FCount = 0 then
    Exit(nil);
  Result := FItems[FHead];
  FItems[FHead] := nil;
  FHead := (FHead + 1) mod Length(FItems);
  Dec(FCount);
end;

procedure TTaskQueue.Discard(Group: Pointer; All: Boolean);
var
  Kept: TWebTaskArray;
  KeptCount, Index: Integer;
  Task: TWebTask;
begin
  Kept := nil;
  SetLength(Kept, Length(FItems));
  KeptCount := 0;
  for Index := 0 to FCount - 1 do
  begin
    Task := GetItem(Index);
    if All or (Task.Group = Group) then
      Task.Free
    else
    begin
      Kept[KeptCount] := Task;
      Inc(KeptCount);
    end;
  end;
  FItems := Kept;
  FHead := 0;
  FCount := KeptCount;
end;

end.
