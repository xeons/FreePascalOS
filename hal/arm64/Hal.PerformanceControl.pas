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
  Choosing the processor's clock rate: on AArch64 nothing of the kind is
  driven here (the Raspberry Pi's clock is the firmware's,
  Power.BoardClocks); every call reports that there is none.
}
unit Hal.PerformanceControl;

{$mode objfpc}

interface

type
  THardwarePStateCapabilities = record
    Highest: Byte;
    Guaranteed: Byte;
    MostEfficient: Byte;
    Lowest: Byte;
  end;

function PerformanceControlIsAvailable: Boolean;
procedure WriteThisProcessorPerformanceControl(Value: LongWord);
function HardwarePStatesAreAvailable: Boolean;
procedure EnableHardwarePStatesOnThisProcessor;
function ReadHardwarePStateCapabilities(out Capabilities: THardwarePStateCapabilities): Boolean;
procedure RequestThisProcessorHardwarePStates(Lowest, Highest, EnergyPreference: Byte);
function HardwarePStateLevelMegahertz: LongWord;

implementation

function PerformanceControlIsAvailable: Boolean;
begin
  Result := False;
end;

procedure WriteThisProcessorPerformanceControl(Value: LongWord);
begin
end;

function HardwarePStatesAreAvailable: Boolean;
begin
  Result := False;
end;

procedure EnableHardwarePStatesOnThisProcessor;
begin
end;

function ReadHardwarePStateCapabilities(out Capabilities: THardwarePStateCapabilities): Boolean;
begin
  Capabilities.Highest := 0;
  Capabilities.Guaranteed := 0;
  Capabilities.MostEfficient := 0;
  Capabilities.Lowest := 0;
  Result := False;
end;

procedure RequestThisProcessorHardwarePStates(Lowest, Highest, EnergyPreference: Byte);
begin
end;

function HardwarePStateLevelMegahertz: LongWord;
begin
  Result := 0;
end;

end.
