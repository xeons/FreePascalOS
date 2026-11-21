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
  How large the block cache may grow, from the memory there is.

  The cache starts at its minimum and grows on misses while memory is
  plentiful, up to its maximum; under memory pressure it shrinks back
  towards the minimum (Io.BlockCache). By default the maximum is half
  the memory free when the cache starts and the minimum 4 MiB (less on
  a machine with very little memory: a sixteenth of what is free, at
  least 256 KiB). The kernel options blockcache=MIB (the maximum),
  blockcachemin=MIB and blockcacheshare=PERCENT (of free memory, 1 to
  90) change that; the maximum never exceeds 90% of the free memory and
  never falls below the minimum.

  Pure arithmetic, so that the host test (tools/CachePolicyTest) can
  check it.
}
unit Io.BlockCacheSizing;

{$mode objfpc}

interface

const
  CachePageBytes = 4096;
  DefaultCacheSharePercent = 50;
  LargestCacheSharePercent = 90;
  DefaultMinimumCacheBytes = 4 * 1024 * 1024;
  SmallestCacheBytes = 256 * 1024;

type
  { Kernel options; 0 for not given. }
  TBlockCacheSizingOptions = record
    MaximumMegabytes: QWord;
    MinimumMegabytes: QWord;
    SharePercent: QWord;
  end;

  TBlockCacheSize = record
    MinimumLines: QWord;
    MaximumLines: QWord;
  end;

{ The bounds for a cache of 4 KiB lines when FreePages pages are free. }
function ChooseBlockCacheSize(FreePages: QWord; const Options: TBlockCacheSizingOptions): TBlockCacheSize;

implementation

function LinesForMegabytes(Megabytes: QWord): QWord;
begin
  Result := Megabytes * ((1024 * 1024) div CachePageBytes);
end;

function ChooseBlockCacheSize(FreePages: QWord; const Options: TBlockCacheSizingOptions): TBlockCacheSize;
var
  Share: QWord;
  Ceiling: QWord;
  Smallest: QWord;
begin
  Smallest := SmallestCacheBytes div CachePageBytes;
  Ceiling := FreePages div 100 * LargestCacheSharePercent + FreePages mod 100 * LargestCacheSharePercent div 100;
  if Ceiling < Smallest then
    Ceiling := Smallest;

  if Options.MinimumMegabytes > 0 then
    Result.MinimumLines := LinesForMegabytes(Options.MinimumMegabytes)
  else
  begin
    Result.MinimumLines := DefaultMinimumCacheBytes div CachePageBytes;
    if Result.MinimumLines > FreePages div 16 then
      Result.MinimumLines := FreePages div 16;
  end;
  if Result.MinimumLines < Smallest then
    Result.MinimumLines := Smallest;
  if Result.MinimumLines > Ceiling then
    Result.MinimumLines := Ceiling;

  if Options.MaximumMegabytes > 0 then
    Result.MaximumLines := LinesForMegabytes(Options.MaximumMegabytes)
  else
  begin
    Share := Options.SharePercent;
    if (Share = 0) or (Share > LargestCacheSharePercent) then
      Share := DefaultCacheSharePercent;
    Result.MaximumLines := FreePages div 100 * Share + FreePages mod 100 * Share div 100;
  end;
  if Result.MaximumLines > Ceiling then
    Result.MaximumLines := Ceiling;
  if Result.MaximumLines < Result.MinimumLines then
    Result.MaximumLines := Result.MinimumLines;
end;

end.
