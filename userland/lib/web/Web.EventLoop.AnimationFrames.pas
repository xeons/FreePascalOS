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
  requestAnimationFrame and cancelAnimationFrame (HTML Standard section
  8.10): a window's map of animation frame callbacks, ids from 1 up.
  "Run the animation frame callbacks" takes the ids present when it
  starts; a callback requested meanwhile waits for the next frame, one
  cancelled meanwhile does not run. The loop does a microtask checkpoint
  after each callback (the caller passes a routine for it).
}
unit Web.EventLoop.AnimationFrames;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TAnimationFrameCallback = class
  public
    procedure Invoke(Timestamp: Double); virtual; abstract;
  end;

  TAnimationFrameEntry = record
    Id: LongInt;
    Callback: TAnimationFrameCallback;
  end;

  TAfterCallbackStep = procedure of object;

  TAnimationFrameList = class
  private
    FEntries: array of TAnimationFrameEntry;
    FCount: Integer;
    FNextId: LongInt;
    FExceptionCount: Integer;
    function IndexOfId(Id: LongInt): Integer;
    procedure RemoveAt(Index: Integer);
  public
    destructor Destroy; override;
    { The callback's id; the list owns Callback. }
    function Request(Callback: TAnimationFrameCallback): LongInt;
    procedure Cancel(Id: LongInt);
    { Runs the callbacks present now, AfterEach after each one. }
    procedure Run(Timestamp: Double; AfterEach: TAfterCallbackStep = nil);
    procedure Clear;
    property Count: Integer read FCount;
    property ExceptionCount: Integer read FExceptionCount;
  end;

implementation

destructor TAnimationFrameList.Destroy;
begin
  Clear;
  inherited Destroy;
end;

function TAnimationFrameList.IndexOfId(Id: LongInt): Integer;
var
  Low_, High_, Middle: Integer;
begin
  { Ids only grow, so the entries are sorted by id. }
  Low_ := 0;
  High_ := FCount - 1;
  while Low_ <= High_ do
  begin
    Middle := (Low_ + High_) div 2;
    if FEntries[Middle].Id = Id then
      Exit(Middle);
    if FEntries[Middle].Id < Id then
      Low_ := Middle + 1
    else
      High_ := Middle - 1;
  end;
  Result := -1;
end;

procedure TAnimationFrameList.RemoveAt(Index: Integer);
var
  Move_: Integer;
begin
  for Move_ := Index to FCount - 2 do
    FEntries[Move_] := FEntries[Move_ + 1];
  Dec(FCount);
  FEntries[FCount].Callback := nil;
end;

function TAnimationFrameList.Request(Callback: TAnimationFrameCallback): LongInt;
begin
  Inc(FNextId);
  if FCount = Length(FEntries) then
    SetLength(FEntries, FCount * 2 + 4);
  FEntries[FCount].Id := FNextId;
  FEntries[FCount].Callback := Callback;
  Inc(FCount);
  Result := FNextId;
end;

procedure TAnimationFrameList.Cancel(Id: LongInt);
var
  Index: Integer;
  Callback: TAnimationFrameCallback;
begin
  Index := IndexOfId(Id);
  if Index < 0 then
    Exit;
  Callback := FEntries[Index].Callback;
  RemoveAt(Index);
  Callback.Free;
end;

procedure TAnimationFrameList.Run(Timestamp: Double; AfterEach: TAfterCallbackStep);
var
  Ids: array of LongInt;
  Index, Position: Integer;
  Callback: TAnimationFrameCallback;
begin
  Ids := nil;
  SetLength(Ids, FCount);
  for Index := 0 to FCount - 1 do
    Ids[Index] := FEntries[Index].Id;
  for Index := 0 to High(Ids) do
  begin
    Position := IndexOfId(Ids[Index]);
    if Position < 0 then
      Continue;
    Callback := FEntries[Position].Callback;
    RemoveAt(Position);
    try
      try
        Callback.Invoke(Timestamp);
      except
        { Reported, and the other callbacks still run. }
        on Error: Exception do
          Inc(FExceptionCount);
      end;
    finally
      Callback.Free;
    end;
    if Assigned(AfterEach) then
      AfterEach();
  end;
end;

procedure TAnimationFrameList.Clear;
var
  Index: Integer;
begin
  for Index := 0 to FCount - 1 do
    FEntries[Index].Callback.Free;
  FCount := 0;
  FEntries := nil;
end;

end.
