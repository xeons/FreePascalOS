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
  Evicting mapped file pages under memory pressure (a shrinker of
  Memory.Pressure).

  A page of a mapped file (Processes.MappedFiles) may be dropped when it
  is clean (not waiting to be written back) and can be read again: a
  snapshot's preserved pages, and every page of a damaged snapshot,
  stay. Gently, only pages no process maps go (nothing but the mapped
  file holds them: a library nobody runs any more, pages of a file
  unmapped long ago that an image section keeps). Hard, mapped pages go
  too: their mappings are removed (Processes.MappedFileMappings) and the
  next touch reads them again - but only as many as the thrash guard
  allows (Memory.ThrashGuard: a few a second), so a program that keeps
  asking for memory is ended for it rather than every program being
  made to read its code from disk again and again.

  Each mapped file is looked at from where the last pass stopped (its
  eviction cursor), so the pages taken rotate through the file. The
  shrinker never takes a volume's lock or writes anything back (that
  happens on the background writer): it only unmaps and frees.
}
unit Processes.MappedFileEviction;

{$mode objfpc}
{$pointermath on}

interface

uses
  Memory.Pressure;

procedure InitializeMappedFileEviction;
{ Frees up to PagesWanted pages of mapped files; returns how many it
  freed. Passive level. }
function EvictMappedFilePages(PagesWanted: QWord; Urgency: TShrinkUrgency): QWord;
{ Mapped pages the thrash guard kept from being evicted, since start. }
function ThrashGuardRefusedPages: QWord;

implementation

uses
  Kernel.Clock,
  Memory.PhysicalPages,
  Memory.ThrashGuard,
  Processes.MappedFiles,
  Processes.MappedFileMappings;

var
  { Used only by the shrinker, which Memory.Pressure runs one at a time. }
  Guard: TThrashGuard;
  GuardReady: Boolean = False;

const
  CandidateBatch = 64;

{ One batch of one mapped file; returns the pages freed, and whether
  there were candidates at all. }
function EvictBatch(MappedFile: PMappedFile; Wanted: QWord; UnmapFirst: Boolean;
  out HadCandidates: Boolean): QWord;
var
  Pages: array[0..CandidateBatch - 1] of TMappedPageReference;
  Count: Integer;
  Index: Integer;
begin
  Result := 0;
  if Wanted > CandidateBatch then
    Wanted := CandidateBatch;
  Count := TakeEvictionCandidates(MappedFile, @Pages[0], Integer(Wanted));
  HadCandidates := Count > 0;
  if UnmapFirst then
    UnmapMappedPages(MappedFile, @Pages[0], Count);
  for Index := 0 to Count - 1 do
    if DropEvictionCandidate(MappedFile, Pages[Index]) then
      Inc(Result);
end;

{ Passes over every mapped file until enough is freed or a pass frees
  nothing. }
function EvictPass(PagesWanted: QWord; UnmapFirst: Boolean): QWord;
var
  Files: PPMappedFile;
  Count: Integer;
  Index: Integer;
  Freed: QWord;
  HadCandidates: Boolean;
  Progress: Boolean;
  Rounds: Integer;
begin
  Result := 0;
  if not ListMappedFiles(nil, 0, True, Files, Count) then
    Exit;
  Rounds := 0;
  repeat
    Progress := False;
    for Index := 0 to Count - 1 do
    begin
      if Result >= PagesWanted then
        Break;
      Freed := EvictBatch(Files[Index], PagesWanted - Result, UnmapFirst, HadCandidates);
      Result := Result + Freed;
      if Freed > 0 then
        Progress := True;
    end;
    Inc(Rounds);
  until (Result >= PagesWanted) or not Progress or (Rounds >= 64);
  FreeMappedFileList(Files, Count);
end;

procedure EnsureGuard;
var
  Physical: TPhysicalMemoryStatistics;
begin
  if GuardReady then
    Exit;
  GetPhysicalMemoryStatistics(Physical);
  InitializeThrashGuard(Guard, ThrashGuardRate(Physical.TotalUsablePages), ClockNanoseconds);
  GuardReady := True;
end;

{ Mapped pages, within what the thrash guard grants. }
function EvictMappedPagesGuarded(PagesWanted: QWord): QWord;
var
  Granted: QWord;
begin
  EnsureGuard;
  Granted := TakeThrashGuardPages(Guard, PagesWanted, ClockNanoseconds);
  if Granted = 0 then
    Exit(0);
  Result := EvictPass(Granted, True);
  if Result < Granted then
    ReturnThrashGuardPages(Guard, Granted - Result);
end;

function EvictMappedFilePages(PagesWanted: QWord; Urgency: TShrinkUrgency): QWord;
begin
  Result := EvictPass(PagesWanted, False);
  if (Result < PagesWanted) and (Urgency = ShrinkHard) then
    Result := Result + EvictMappedPagesGuarded(PagesWanted - Result);
end;

function ThrashGuardRefusedPages: QWord;
begin
  if not GuardReady then
    Exit(0);
  Result := Guard.Refused;
end;

procedure InitializeMappedFileEviction;
begin
  RegisterShrinker('mapped files', @EvictMappedFilePages);
end;

end.
