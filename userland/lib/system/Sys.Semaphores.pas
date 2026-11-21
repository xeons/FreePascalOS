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
  TSemaphore: a kernel semaphore (Sys.Objects) as an object.

  It counts from 0 to a limit: Acquire takes one (waiting while there
  are none, at most the timeout), Release gives some back. The handle
  can be waited on with others (WaitForHandles, WaitForAllHandles) and
  passed to another process in a message, so threads of different
  processes can share one. Destroying the object closes its handle.
}
unit Sys.Semaphores;

{$mode objfpc}

interface

uses
  SysUtils,
  Abi.SystemCalls;

type
  ESemaphoreError = class(Exception);

  TSemaphore = class
  private
    FHandle: Int64;
    FOwnsHandle: Boolean;
    function GetCount: LongInt;
  public
    { A new semaphore; raises ESemaphoreError if the kernel refuses it
      (a count or limit out of range, no memory or handles left). }
    constructor Create(InitialCount: LongInt; Limit: LongInt = MaximumSemaphoreLimit);
    { Wraps a semaphore handle received from elsewhere; closed on
      destruction if OwnsHandle. }
    constructor CreateFromHandle(Handle: Int64; OwnsHandle: Boolean = True);
    destructor Destroy; override;
    { Takes one, waiting at most Timeout milliseconds (InfiniteWait for
      no limit, 0 only to try); False if the time ran out first. }
    function Acquire(Timeout: Int64 = InfiniteWait): Boolean;
    { Gives back ReleaseCount; False, changing nothing, if that would
      pass the limit. }
    function Release(ReleaseCount: LongInt = 1): Boolean;
    property Handle: Int64 read FHandle;
    property Count: LongInt read GetCount;
  end;

implementation

uses
  Sys.Errors,
  Sys.Objects;

constructor TSemaphore.Create(InitialCount: LongInt; Limit: LongInt);
begin
  inherited Create;
  FHandle := CreateSemaphore(InitialCount, Limit);
  if FHandle < 0 then
    raise ESemaphoreError.CreateFmt('could not create a semaphore: %s',
      [string(ErrorMessage(ErrorCodeOf(FHandle)))]);
  FOwnsHandle := True;
end;

constructor TSemaphore.CreateFromHandle(Handle: Int64; OwnsHandle: Boolean);
begin
  inherited Create;
  FHandle := Handle;
  FOwnsHandle := OwnsHandle;
end;

destructor TSemaphore.Destroy;
begin
  if FOwnsHandle and (FHandle >= 0) then
    CloseHandle(FHandle);
  inherited Destroy;
end;

function TSemaphore.Acquire(Timeout: Int64): Boolean;
begin
  Result := WaitForHandle(FHandle, Timeout) = ErrorNone;
end;

function TSemaphore.Release(ReleaseCount: LongInt): Boolean;
var
  PreviousCount: LongInt;
begin
  Result := ReleaseSemaphore(FHandle, ReleaseCount, PreviousCount) = ErrorNone;
end;

function TSemaphore.GetCount: LongInt;
var
  CallResult: Int64;
begin
  CallResult := GetSemaphoreCount(FHandle);
  if CallResult < 0 then
    Exit(0);
  Result := LongInt(CallResult);
end;

end.
