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
  The whole system's processor time and memory (TAbiSystemUsage): each
  processor's busy and idle time, the number of processes and threads,
  and what the memory is used for.

  The processors' times only grow, so how busy they are comes from two
  samples: the busy time added between them over all the time added
  (ProcessorBusyTenths, AllProcessorsBusyTenths).
}
unit Sys.SystemUsage;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

type
  TSystemUsage = TAbiSystemUsage;

function GetSystemUsage(out Usage: TSystemUsage): LongInt;

{ How busy processor Index was between two samples, in tenths of a
  percent (0 if it did not run). }
function ProcessorBusyTenths(const Earlier, Later: TSystemUsage; Index: LongInt): LongWord;
{ The same over every processor: 1000 is all of them busy. }
function AllProcessorsBusyTenths(const Earlier, Later: TSystemUsage): LongWord;
{ How many processors run. }
function OnlineProcessors(const Usage: TSystemUsage): LongWord;
{ The memory in use: all of it but what is free. }
function UsedMemory(const Usage: TSystemUsage): QWord;

implementation

uses
  Sys.Kernel,
  Sys.Errors;

function GetSystemUsage(out Usage: TSystemUsage): LongInt;
begin
  Result := ErrorCodeOf(KernelGetSystemUsage(Usage));
end;

{ Busy share of the time added between two samples of one processor. }
function BusyShareTenths(EarlierBusy, EarlierIdle, LaterBusy, LaterIdle: QWord): LongWord;
var
  BusyAdded: QWord;
  AllAdded: QWord;
begin
  if (LaterBusy < EarlierBusy) or (LaterIdle < EarlierIdle) then
    Exit(0);
  BusyAdded := LaterBusy - EarlierBusy;
  AllAdded := BusyAdded + (LaterIdle - EarlierIdle);
  if AllAdded = 0 then
    Exit(0);
  Result := LongWord((BusyAdded * 1000 + AllAdded div 2) div AllAdded);
end;

function ProcessorBusyTenths(const Earlier, Later: TSystemUsage; Index: LongInt): LongWord;
begin
  if (Index < 0) or (Index >= AbiMaximumProcessors) or (Later.Processors[Index].Online = 0) then
    Exit(0);
  Result := BusyShareTenths(Earlier.Processors[Index].BusyNanoseconds, Earlier.Processors[Index].IdleNanoseconds,
    Later.Processors[Index].BusyNanoseconds, Later.Processors[Index].IdleNanoseconds);
end;

function AllProcessorsBusyTenths(const Earlier, Later: TSystemUsage): LongWord;
var
  Index: LongInt;
  EarlierBusy: QWord;
  EarlierIdle: QWord;
  LaterBusy: QWord;
  LaterIdle: QWord;
begin
  EarlierBusy := 0;
  EarlierIdle := 0;
  LaterBusy := 0;
  LaterIdle := 0;
  for Index := 0 to AbiMaximumProcessors - 1 do
    if (Later.Processors[Index].Online <> 0) and (Earlier.Processors[Index].Online <> 0) then
    begin
      EarlierBusy := EarlierBusy + Earlier.Processors[Index].BusyNanoseconds;
      EarlierIdle := EarlierIdle + Earlier.Processors[Index].IdleNanoseconds;
      LaterBusy := LaterBusy + Later.Processors[Index].BusyNanoseconds;
      LaterIdle := LaterIdle + Later.Processors[Index].IdleNanoseconds;
    end;
  Result := BusyShareTenths(EarlierBusy, EarlierIdle, LaterBusy, LaterIdle);
end;

function OnlineProcessors(const Usage: TSystemUsage): LongWord;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to AbiMaximumProcessors - 1 do
    if Usage.Processors[Index].Online <> 0 then
      Inc(Result);
end;

function UsedMemory(const Usage: TSystemUsage): QWord;
begin
  if Usage.FreeMemory > Usage.TotalMemory then
    Exit(0);
  Result := Usage.TotalMemory - Usage.FreeMemory;
end;

end.
