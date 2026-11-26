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
  What a test child may use, so a runaway page cannot take the host
  down (the host has no swap; a test run without caps once had the
  kernel's out-of-memory killer end the desktop session): each child's
  address space (WPT_CHILD_MEMORY_MB, 2048 by default) and CPU time (a
  backstop behind the runner's own timeouts), and no more jobs than fit
  in half the memory available when the run starts.
}
unit WptRun.Limits;

{$mode objfpc}
{$H+}

interface

{ Called first thing in a child (wptrun --child). }
procedure LimitChildResources;
{ Jobs, lowered to what half the host's available memory holds at the
  child cap (at least one). }
function JobsThatFitInMemory(Jobs: Integer): Integer;

implementation

uses
  SysUtils,
  Classes,
  BaseUnix,
  Unix;

const
  DefaultChildMemoryMegabytes = 2048;
  { CPU seconds: longer than any test's timeout (75 s for long ones)
    plus the kill slack, so only a child the runner failed to stop hits
    it. }
  ChildCpuSeconds = 120;

function ChildMemoryCap: Int64;
begin
  Result := StrToInt64Def(GetEnvironmentVariable('WPT_CHILD_MEMORY_MB'), DefaultChildMemoryMegabytes);
  if Result < 256 then
    Result := 256;
  Result := Result * 1024 * 1024;
end;

procedure LimitChildResources;
var
  Limit: TRLimit;
begin
  Limit.rlim_cur := ChildMemoryCap;
  Limit.rlim_max := ChildMemoryCap;
  FpSetRLimit(RLIMIT_AS, @Limit);
  Limit.rlim_cur := ChildCpuSeconds;
  Limit.rlim_max := ChildCpuSeconds;
  FpSetRLimit(RLIMIT_CPU, @Limit);
end;

function HostAvailableMemory: Int64;
var
  Lines: TStringList;
  Line: string;
  Parts: TStringArray;
begin
  Result := 0;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile('/proc/meminfo');
    except
      on EStreamError do
        Exit;
    end;
    for Line in Lines do
      if Pos('MemAvailable:', Line) = 1 then
      begin
        Parts := Trim(Copy(Line, Length('MemAvailable:') + 1, MaxInt)).Split([' ']);
        if Length(Parts) > 0 then
          Result := StrToInt64Def(Parts[0], 0) * 1024;
        Break;
      end;
  finally
    Lines.Free;
  end;
end;

function JobsThatFitInMemory(Jobs: Integer): Integer;
var
  Available: Int64;
  Fitting: Int64;
begin
  Result := Jobs;
  Available := HostAvailableMemory;
  if Available > 0 then
  begin
    Fitting := (Available div 2) div ChildMemoryCap;
    if Fitting < Result then
      Result := Fitting;
  end;
  if Result < 1 then
    Result := 1;
end;

end.
