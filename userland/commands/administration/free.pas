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
  free - show the memory in use and free

  free [-b|-k|-m|-h]

  The RAM there is, what is used, free, held by the block cache (given
  back when memory runs short) and available (free plus the cache above
  its minimum); then the cache's size, bounds and hit rate, and memory
  pressure: the watermarks, what the caches gave back and how many
  processes were ended for want of memory.
}
program free;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.SystemUsage,
  Sys.MemoryStatus,
  Sys.Streams,
  Util.CommandLine,
  Util.Sizes;

const
  Usage = 'Usage: free [OPTION]...'#10 +
    'Show the memory in use and free, the disk cache and memory pressure.'#10 +
    #10 +
    '  -b, --bytes          sizes in bytes'#10 +
    '  -k, --kibi           sizes in KiB (the default)'#10 +
    '  -m, --mebi           sizes in MiB'#10 +
    '  -h, --human          sizes with units'#10;

  OptionBytes = 1;
  OptionKibi = 2;
  OptionMebi = 3;
  OptionHuman = 4;

type
  TUnit = (UnitBytes, UnitKibi, UnitMebi, UnitHuman);

var
  SizeUnit: TUnit;

function SizeColumn(Bytes: QWord): string;
begin
  case SizeUnit of
    UnitBytes: Result := IntToStr(Bytes);
    UnitMebi: Result := IntToStr(Bytes div (1024 * 1024));
    UnitHuman: Result := FormatHumanSize(Bytes);
  else
    Result := IntToStr(Bytes div 1024);
  end;
  Result := Format('%12s', [Result]);
end;

procedure ShowMemory(const SystemUsage: TSystemUsage; const Cache: TBlockCacheStatistics);
var
  CacheMemory: QWord;
  Used: QWord;
  Spare: QWord;
begin
  CacheMemory := CacheBytes(Cache);
  Used := UsedMemory(SystemUsage);
  if Used > CacheMemory then
    Used := Used - CacheMemory
  else
    Used := 0;
  Spare := 0;
  if Cache.LineCount > Cache.MinimumLines then
    Spare := (Cache.LineCount - Cache.MinimumLines) * Cache.LineBytes;
  PrintStringLine('     ' + Format('%12s%12s%12s%12s%12s', ['total', 'used', 'free', 'cache', 'available']));
  PrintStringLine('Mem: ' + SizeColumn(SystemUsage.TotalMemory) + SizeColumn(Used) +
    SizeColumn(SystemUsage.FreeMemory) + SizeColumn(CacheMemory) + SizeColumn(SystemUsage.FreeMemory + Spare));
end;

procedure ShowCache(const Cache: TBlockCacheStatistics);
var
  Tenths: LongWord;
begin
  Tenths := CacheHitTenths(Cache);
  PrintStringLine(Format('Cache: %s in %d lines (%s to %s), %d.%d%% hits, %d dirty, %d grown, %d given back',
    [FormatHumanSize(CacheBytes(Cache)), Cache.LineCount, FormatHumanSize(Cache.MinimumLines * Cache.LineBytes),
     FormatHumanSize(Cache.MaximumLines * Cache.LineBytes), Tenths div 10, Tenths mod 10, Cache.DirtyLines,
     Cache.LinesGrown, Cache.LinesShrunk]));
end;

procedure ShowPressure(const Pressure: TMemoryPressure);
const
  PageBytes = 4096;
var
  Line: string;
begin
  Line := Format('Pressure: %s (low below %s, critical below %s), %d pages given back',
    [PressureLevelName(Pressure.Level), FormatHumanSize(Pressure.LowWatermarkPages * PageBytes),
     FormatHumanSize(Pressure.CriticalWatermarkPages * PageBytes), Pressure.ReclaimedPages]);
  Line := Line + Format(', %d processes ended for memory', [Pressure.ProcessesEnded]);
  if Pressure.ProcessesEnded > 0 then
    Line := Line + Format(' (last %s, %d)', [PChar(@Pressure.LastEndedName[0]), Pressure.LastEndedProcessId]);
  PrintStringLine(Line);
end;

procedure ShowCommit(const Pressure: TMemoryPressure);
const
  PageBytes = 4096;
var
  Line: string;
begin
  Line := Format('Commit: %s committed', [FormatHumanSize(Pressure.CommittedPages * PageBytes)]);
  case Pressure.CommitPolicy of
    AbiCommitPolicyStrict:
      Line := Line + Format(' of %s (strict)', [FormatHumanSize(Pressure.CommitLimitPages * PageBytes)]);
    AbiCommitPolicyOvercommit:
      Line := Line + Format(' of %s (overcommit, one commitment up to %s)',
        [FormatHumanSize(Pressure.CommitLimitPages * PageBytes),
         FormatHumanSize(Pressure.LargestCommitPages * PageBytes)]);
  else
    Line := Line + ' (no limit)';
  end;
  PrintStringLine(Line + Format(', %d refused', [Pressure.CommitFailures]));
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  SystemUsage: TSystemUsage;
  Cache: TBlockCacheStatistics;
  Pressure: TMemoryPressure;
begin
  SizeUnit := UnitKibi;
  CommandLine := TCommandLine.Create([
    CommandOption('b', 'bytes', False, OptionBytes),
    CommandOption('k', 'kibi', False, OptionKibi),
    CommandOption('m', 'mebi', False, OptionMebi),
    CommandOption('h', 'human', False, OptionHuman)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionBytes: SizeUnit := UnitBytes;
      OptionKibi: SizeUnit := UnitKibi;
      OptionMebi: SizeUnit := UnitMebi;
      OptionHuman: SizeUnit := UnitHuman;
    end;
  CommandLine.Free;
  if (GetSystemUsage(SystemUsage) <> 0) or (GetBlockCacheStatistics(Cache) <> 0) or
     (GetMemoryPressure(Pressure) <> 0) then
  begin
    PrintErrorStringLine('free: the kernel did not report its memory');
    Halt(1);
  end;
  ShowMemory(SystemUsage, Cache);
  ShowCache(Cache);
  ShowPressure(Pressure);
  ShowCommit(Pressure);
end.
