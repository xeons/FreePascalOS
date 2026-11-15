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
  Power handlers: what each part of the system does around suspend to
  RAM.

  Suspend to RAM turns every device off, and waking resets them: only
  memory keeps its contents. Each part that owns hardware (PCI, drivers,
  frameworks) registers a handler with a suspend routine (quiet the
  hardware: no requests in flight, nothing running) and a resume
  routine (set the hardware up again from what memory still holds), and
  a stage saying where in the order it belongs: resuming runs the stages
  from the first up, suspending from the last down.
}
unit Io.PowerManagement;

{$mode objfpc}

interface

const
  { Resume order (suspend runs the other way round). }
  PowerStagePlatform = 0;    { PCI configuration space, message interrupts }
  PowerStageFirmware = 1;    { ACPI }
  PowerStageBuses = 2;       { controllers others sit on (USB) }
  PowerStageDevices = 3;     { drivers }
  PowerStageServices = 4;    { frameworks above drivers (audio, block I/O) }

type
  TPowerRoutine = procedure(Context: Pointer);

procedure RegisterPowerHandler(Name: PChar; Stage: Integer; Suspend, Resume: TPowerRoutine; Context: Pointer);
{ Runs every suspend routine, last stage first. }
procedure SuspendPowerHandlers;
{ Runs every resume routine, first stage first. }
procedure ResumePowerHandlers;

implementation

uses
  Debug.Output;

const
  MaximumHandlers = 64;

type
  TPowerHandler = record
    Name: PChar;
    Stage: Integer;
    Suspend: TPowerRoutine;
    Resume: TPowerRoutine;
    Context: Pointer;
  end;

var
  Handlers: array[0..MaximumHandlers - 1] of TPowerHandler;
  HandlerCount: Integer;

procedure RegisterPowerHandler(Name: PChar; Stage: Integer; Suspend, Resume: TPowerRoutine; Context: Pointer);
begin
  if HandlerCount = MaximumHandlers then
  begin
    DebugBeginMessage;
    DebugWriteTag('power');
    DebugWrite('too many power handlers: ');
    DebugWriteLine(Name);
    DebugEndMessage;
    Exit;
  end;
  Handlers[HandlerCount].Name := Name;
  Handlers[HandlerCount].Stage := Stage;
  Handlers[HandlerCount].Suspend := Suspend;
  Handlers[HandlerCount].Resume := Resume;
  Handlers[HandlerCount].Context := Context;
  Inc(HandlerCount);
end;

procedure SuspendPowerHandlers;
var
  Stage: Integer;
  Index: Integer;
begin
  for Stage := PowerStageServices downto PowerStagePlatform do
    for Index := HandlerCount - 1 downto 0 do
      if (Handlers[Index].Stage = Stage) and Assigned(Handlers[Index].Suspend) then
        Handlers[Index].Suspend(Handlers[Index].Context);
end;

procedure ResumePowerHandlers;
var
  Stage: Integer;
  Index: Integer;
begin
  for Stage := PowerStagePlatform to PowerStageServices do
    for Index := 0 to HandlerCount - 1 do
      if (Handlers[Index].Stage = Stage) and Assigned(Handlers[Index].Resume) then
        Handlers[Index].Resume(Handlers[Index].Context);
end;

end.
