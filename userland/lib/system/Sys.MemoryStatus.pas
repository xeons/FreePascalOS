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
  The block cache, memory pressure and the out-of-memory policy, as the
  kernel reports them (CallGetBlockCacheStatistics,
  CallGetMemoryPressure), discarding a volume's free space
  (CallTrimVolume, root only), and the process's OOM score adjustment
  and process count limit (CallSetProcessLimit).

  Functions returning LongInt give 0 or an Abi error code.
}
unit Sys.MemoryStatus;

{$mode objfpc}{$H+}

interface

uses
  Abi.SystemCalls;

type
  TBlockCacheStatistics = TAbiBlockCacheStatistics;
  TMemoryPressure = TAbiMemoryPressure;

function GetBlockCacheStatistics(out Statistics: TBlockCacheStatistics): LongInt;
function GetMemoryPressure(out Pressure: TMemoryPressure): LongInt;
{ Bytes in the cache now. }
function CacheBytes(const Statistics: TBlockCacheStatistics): QWord;
{ Hits among all lookups, in tenths of a percent (0 without lookups). }
function CacheHitTenths(const Statistics: TBlockCacheStatistics): LongWord;
function PressureLevelName(Level: LongWord): string;

{ Discards the free space of the volume holding Path; Discarded gets
  the bytes the disk took. }
function TrimVolume(const Path: string; out Discarded: QWord): LongInt;

{ -1000 (never chosen unless asking) to 1000 (chosen first); Previous
  gets the old one. Lowering below 0 needs root. }
function SetOomScoreAdjust(Adjust: LongInt; out Previous: LongInt): LongInt;
{ The most processes this user may run while this process starts one. }
function SetProcessCountLimit(Limit: LongWord): LongInt;

implementation

uses
  Sys.Errors;

function GetBlockCacheStatistics(out Statistics: TBlockCacheStatistics): LongInt;
begin
  FillChar(Statistics, SizeOf(Statistics), 0);
  Result := ErrorCodeOf(SystemCall(CallGetBlockCacheStatistics, QWord(@Statistics), 0, 0, 0, 0, 0));
end;

function GetMemoryPressure(out Pressure: TMemoryPressure): LongInt;
begin
  FillChar(Pressure, SizeOf(Pressure), 0);
  Result := ErrorCodeOf(SystemCall(CallGetMemoryPressure, QWord(@Pressure), 0, 0, 0, 0, 0));
end;

function CacheBytes(const Statistics: TBlockCacheStatistics): QWord;
begin
  Result := Statistics.LineCount * Statistics.LineBytes;
end;

function CacheHitTenths(const Statistics: TBlockCacheStatistics): LongWord;
var
  Lookups: QWord;
begin
  Lookups := Statistics.Hits + Statistics.Misses;
  if Lookups = 0 then
    Exit(0);
  Result := LongWord((Statistics.Hits * 1000) div Lookups);
end;

function PressureLevelName(Level: LongWord): string;
begin
  case Level of
    AbiMemoryPressureNone: Result := 'none';
    AbiMemoryPressureLow: Result := 'low';
    AbiMemoryPressureCritical: Result := 'critical';
  else
    Result := 'unknown';
  end;
end;

function TrimVolume(const Path: string; out Discarded: QWord): LongInt;
var
  CallResult: Int64;
begin
  Discarded := 0;
  CallResult := SystemCall(CallTrimVolume, QWord(PChar(Path)), 0, 0, 0, 0, 0);
  Result := ErrorCodeOf(CallResult);
  if Result = ErrorNone then
    Discarded := QWord(CallResult);
end;

function SetOomScoreAdjust(Adjust: LongInt; out Previous: LongInt): LongInt;
var
  CallResult: Int64;
begin
  Previous := 0;
  if (Adjust < OomScoreAdjustNever) or (Adjust > OomScoreAdjustOffset) then
    Exit(ErrorInvalidArgument);
  CallResult := SystemCall(CallSetProcessLimit, ProcessLimitOomScoreAdjust,
    QWord(Adjust + OomScoreAdjustOffset), 0, 0, 0, 0);
  Result := ErrorCodeOf(CallResult);
  if Result = ErrorNone then
    Previous := LongInt(CallResult) - OomScoreAdjustOffset;
end;

function SetProcessCountLimit(Limit: LongWord): LongInt;
begin
  Result := ErrorCodeOf(SystemCall(CallSetProcessLimit, ProcessLimitProcesses, Limit, 0, 0, 0, 0));
end;

end.
