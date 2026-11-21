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
  The ARM generic interrupt controller, whichever version the firmware
  describes: GICv2 (Hal.GicV2: the Raspberry Pi 4's GIC-400, QEMU's
  virt machine with gic-version=2) or GICv3 (Hal.GicV3: system register
  CPU interface, redistributors, affinity routing, LPIs through an ITS;
  servers, QEMU with gic-version=3). The ACPI MADT's distributor entry
  gives the version (0, from older firmware, means 2 when it names a CPU
  interface), a device tree its compatible string (Firmware.Madt).

  The kernel's vectors (Hal.InterruptVectors) are given to the INTIDs
  the HAL uses: the dispatch and request SGIs, the timer's PPI, and the
  SPIs and message interrupts drivers connect; each INTID gets the GIC
  priority of its vector's level (Kernel.Arch.PriorityLevel).
}
unit Hal.Gic;

{$mode objfpc}

interface

uses
  Hal.GicDefinitions;

const
  SoftwareInterruptDispatch = Hal.GicDefinitions.SoftwareInterruptDispatch;
  SoftwareInterruptRequest = Hal.GicDefinitions.SoftwareInterruptRequest;
  SoftwareInterruptStop = Hal.GicDefinitions.SoftwareInterruptStop;
  FirstSharedInterrupt = Hal.GicDefinitions.FirstSharedInterrupt;
  SpuriousInterruptId = Hal.GicDefinitions.SpuriousInterruptId;

{ Maps the GIC the MADT (or device tree) describes and sets up the
  distributor and this processor's CPU interface. False if there is
  none, or it is of a version not driven. }
function InitializeGic: Boolean;
{ Sets up a processor's CPU interface and private interrupts. }
procedure InitializeGicOnThisProcessor;
{ After waking from suspend to RAM, on the boot processor: the
  distributor (and a GICv3's ITS) set up again with every connected
  interrupt as it was, if they lost their settings, then this
  processor's interface. }
procedure RestoreGicAfterSleep;

{ 2 or 3; 0 before InitializeGic found one. }
function GicVersion: Byte;
function GicInterruptCount: LongWord;

{ Gives INTID Interrupt the kernel's Vector (a private interrupt on
  every processor, or an SPI) with its level's priority, its trigger,
  and enables it. SPIs go to the processor with id TargetProcessorId. }
function ConnectGicInterrupt(Interrupt: LongWord; Vector: Byte; LevelTriggered: Boolean;
  TargetProcessorId: LongWord): Boolean;
procedure DisableGicInterrupt(Interrupt: LongWord);

{ Acknowledges the highest pending interrupt and returns its vector
  (SpuriousInterruptVector if none, or it has none). }
function AcknowledgeGicInterrupt: Byte;
{ Ends the interrupt this processor acknowledged last. }
procedure EndGicInterrupt;

{ Sends software generated interrupt Number to one processor, to this
  one, or to all others. }
procedure SendSoftwareInterrupt(Number: LongWord; TargetProcessorId: LongWord);
procedure SendSoftwareInterruptToSelf(Number: LongWord);
procedure SendSoftwareInterruptToOthers(Number: LongWord);

function GicIsAvailable: Boolean;

implementation

uses
  Firmware.Madt,
  Hal.GicV2,
  Hal.GicV3;

var
  Version: Byte = 0;

function GicVersion: Byte;
begin
  Result := Version;
end;

function GicIsAvailable: Boolean;
begin
  Result := Version <> 0;
end;

function InitializeGic: Boolean;
var
  Description: TGicDescription;
begin
  Result := False;
  if not ParseMadt then
    Exit;
  Description := GicDescription;
  case Description.Version of
    0, 2:
      if InitializeGicV2(Description) then
        Version := 2;
    3, 4:
      if InitializeGicV3(Description) then
        Version := 3;
  end;
  Result := Version <> 0;
end;

procedure InitializeGicOnThisProcessor;
begin
  case Version of
    2: InitializeGicV2OnThisProcessor;
    3: InitializeGicV3OnThisProcessor;
  end;
end;

procedure RestoreGicAfterSleep;
begin
  case Version of
    2: RestoreGicV2AfterSleep;
    3: RestoreGicV3AfterSleep;
  end;
end;

function GicInterruptCount: LongWord;
begin
  case Version of
    2: Result := GicV2InterruptCount;
    3: Result := GicV3InterruptCount;
  else
    Result := 0;
  end;
end;

function ConnectGicInterrupt(Interrupt: LongWord; Vector: Byte; LevelTriggered: Boolean;
  TargetProcessorId: LongWord): Boolean;
begin
  case Version of
    2: Result := ConnectGicV2Interrupt(Interrupt, Vector, LevelTriggered, TargetProcessorId);
    3: Result := ConnectGicV3Interrupt(Interrupt, Vector, LevelTriggered, TargetProcessorId);
  else
    Result := False;
  end;
end;

procedure DisableGicInterrupt(Interrupt: LongWord);
begin
  case Version of
    2: DisableGicV2Interrupt(Interrupt);
    3: DisableGicV3Interrupt(Interrupt);
  end;
end;

function AcknowledgeGicInterrupt: Byte;
begin
  if Version = 3 then
    Result := AcknowledgeGicV3Interrupt
  else
    Result := AcknowledgeGicV2Interrupt;
end;

procedure EndGicInterrupt;
begin
  if Version = 3 then
    EndGicV3Interrupt
  else
    EndGicV2Interrupt;
end;

procedure SendSoftwareInterrupt(Number: LongWord; TargetProcessorId: LongWord);
begin
  case Version of
    2: SendGicV2SoftwareInterrupt(Number, TargetProcessorId);
    3: SendGicV3SoftwareInterrupt(Number, TargetProcessorId);
  end;
end;

procedure SendSoftwareInterruptToSelf(Number: LongWord);
begin
  case Version of
    2: SendGicV2SoftwareInterruptToSelf(Number);
    3: SendGicV3SoftwareInterruptToSelf(Number);
  end;
end;

procedure SendSoftwareInterruptToOthers(Number: LongWord);
begin
  case Version of
    2: SendGicV2SoftwareInterruptToOthers(Number);
    3: SendGicV3SoftwareInterruptToOthers(Number);
  end;
end;

end.
