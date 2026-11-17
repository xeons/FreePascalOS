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
  Connecting device interrupts to handlers.

  At startup the I/O APICs listed in the ACPI MADT are set up with every
  input masked (without a MADT, the standard single I/O APIC at
  0xFEC00000 is assumed). A driver then asks for its interrupt; it gets
  one of the device vectors (0x30-0x3F) and its handler runs there, at
  device level.

  Interrupts are spread over the processors: each connection goes to the
  next processor in turn, leaving out the boot processor (which also
  keeps time) when there are others. Drivers connect after the other
  processors were started, so they are all there to choose from.

  Global system interrupts (ConnectGlobalInterrupt), as PCI interrupt
  lines arrive on, can be shared: the vector's handler then calls every
  handler connected to the line.

  A PCI device can instead signal its interrupt by writing a message (a
  value to an address) that the processor's local APIC receives
  directly, with no I/O APIC in between. ConnectMessageInterrupt gives
  the address and value to program into the device
  (Io.PciMessageInterrupts).
}
unit Io.InterruptRouting;

{$mode objfpc}

interface

uses
  Kernel.Interrupts;

type
  { What a device writes, and where, to raise its interrupt. }
  TInterruptMessage = record
    Address: QWord;
    Data: LongWord;
  end;

procedure InitializeInterruptRouting;
function InterruptRoutingIsAvailable: Boolean;

{ Connects ISA IRQ Irq (0-15) to Handler. Returns False if no vector is
  free or the IRQ cannot be routed. }
function ConnectIsaInterrupt(Irq: Byte; Handler: TInterruptHandler; Context: Pointer): Boolean;

{ Connects global system interrupt Gsi (an I/O APIC input) to Handler,
  triggered and polarized as given. A line may be shared: several
  handlers on one interrupt are all called each time it fires (each
  must check whether its device raised it). False if no vector is free,
  the interrupt cannot be routed, or a sharer wants it triggered
  differently. }
function ConnectGlobalInterrupt(Gsi: LongWord; LevelTriggered, ActiveLow: Boolean; Handler: TInterruptHandler;
  Context: Pointer): Boolean;
{ The global system interrupt ISA IRQ Irq arrives on. }
function GlobalInterruptOfIsaIrq(Irq: Byte): LongWord;

{ Writes every shared line: its vector, handlers and how often it fired
  (the kernel debug shell's "interrupts"). }
procedure WriteSharedLineSummary;

{ Connects a message signalled interrupt to Handler. Returns False if no
  vector is free. }
function ConnectMessageInterrupt(Handler: TInterruptHandler; Context: Pointer;
  out Message: TInterruptMessage): Boolean;

implementation

uses
  Runtime.Atomic,
  Kernel.Arch.TrapFrame,
  Hal.InterruptVectors,
  Hal.InterruptController,
  Firmware.Madt,
  Kernel.Processors,
  Io.LineInterruptStorms,
  Debug.Output;

var
  Available: Boolean = False;
  { The processor the last interrupt was given to. }
  LastTargetIndex: LongWord = 0;
  NextVector: Integer = DeviceInterruptVectorFirst;

procedure InitializeInterruptRouting;
begin
  Available := InitializeDeviceInterruptRouting(ParseMadt);
  WriteDeviceInterruptRouting;
end;

function InterruptRoutingIsAvailable: Boolean;
begin
  Result := Available;
end;

{ The next processor to take a device interrupt. }
function ChooseTargetProcessor: PProcessor;
var
  Steps: LongWord;
begin
  if OnlineProcessorCount <= 1 then
    Exit(CurrentProcessor);
  Steps := 0;
  repeat
    LastTargetIndex := (LastTargetIndex + 1) mod ProcessorTotal;
    Result := ProcessorByIndex(LastTargetIndex);
    Inc(Steps);
  until ((LastTargetIndex <> 0) and Result^.IsOnline) or (Steps > ProcessorTotal);
  if not Result^.IsOnline then
    Result := CurrentProcessor;
end;

procedure ReportConnection(Source: PChar; Number: LongInt; Vector: Byte; Target: PProcessor);
begin
  DebugBeginMessage;
  DebugWriteTag('interrupts');
  DebugWrite(Source);
  if Number >= 0 then
  begin
    DebugWrite(' ');
    DebugWriteDecimal(Number);
  end;
  DebugWrite(' on vector 0x');
  DebugWriteHex(Vector, 2);
  DebugWrite(', processor ');
  DebugWriteDecimal(Target^.Index);
  DebugWriteLine('');
  DebugEndMessage;
end;

function AllocateVector(Handler: TInterruptHandler; Context: Pointer; out Vector: Byte): Boolean;
begin
  Vector := 0;
  if NextVector >= DeviceInterruptVectorFirst + DeviceInterruptVectorCount then
    Exit(False);
  Vector := Byte(NextVector);
  if not RegisterInterruptHandler(Vector, Handler, Context) then
    Exit(False);
  Inc(NextVector);
  Result := True;
end;

{ Gives back the vector just allocated. }
procedure ReleaseLastVector(Vector: Byte);
begin
  UnregisterInterruptHandler(Vector);
  Dec(NextVector);
end;

function ConnectIsaInterrupt(Irq: Byte; Handler: TInterruptHandler; Context: Pointer): Boolean;
var
  Routing: TIsaInterruptRouting;
  Vector: Byte;
  Target: PProcessor;
begin
  if not Available or not AllocateVector(Handler, Context, Vector) then
    Exit(False);
  Routing := RoutingOfIsaInterrupt(Irq);
  Target := ChooseTargetProcessor;
  if not RouteDeviceInterrupt(Routing.GlobalInterrupt, Vector, Target^.ApicId,
    Routing.ActiveLow, Routing.LevelTriggered) then
  begin
    ReleaseLastVector(Vector);
    Exit(False);
  end;
  ReportConnection('IRQ', Irq, Vector, Target);
  Result := True;
end;

const
  MaximumSharedLines = 16;
  MaximumSharers = 8;

type
  PSharedLine = ^TSharedLine;
  TSharedLine = record
    Gsi: LongWord;
    Vector: Byte;
    LevelTriggered: Boolean;
    ActiveLow: Boolean;
    Count: Integer;
    Handlers: array[0..MaximumSharers - 1] of TInterruptHandler;
    Contexts: array[0..MaximumSharers - 1] of Pointer;
    StormWatch: TLineStormWatch;
  end;

var
  SharedLines: array[0..MaximumSharedLines - 1] of TSharedLine;
  SharedLineCount: Integer;

{ The vector's handler for a line: every handler on it. }
procedure DispatchSharedLine(Frame: PTrapFrame; Context: Pointer);
var
  Line: PSharedLine;
  Index: Integer;
begin
  Line := PSharedLine(Context);
  NoteLineInterrupt(Line^.StormWatch, Line^.Gsi, Line^.Vector);
  for Index := 0 to Line^.Count - 1 do
    Line^.Handlers[Index](Frame, Line^.Contexts[Index]);
end;

function GlobalInterruptOfIsaIrq(Irq: Byte): LongWord;
begin
  Result := RoutingOfIsaInterrupt(Irq).GlobalInterrupt;
end;

function ConnectGlobalInterrupt(Gsi: LongWord; LevelTriggered, ActiveLow: Boolean; Handler: TInterruptHandler;
  Context: Pointer): Boolean;
var
  Index: Integer;
  Line: PSharedLine;
  Vector: Byte;
  Target: PProcessor;
begin
  Result := False;
  if not Available then
    Exit;
  for Index := 0 to SharedLineCount - 1 do
    if SharedLines[Index].Gsi = Gsi then
    begin
      Line := @SharedLines[Index];
      if (Line^.Count = MaximumSharers) or (Line^.LevelTriggered <> LevelTriggered) or
         (Line^.ActiveLow <> ActiveLow) then
        Exit;
      { The handler before the count, so the dispatcher never calls an
        empty slot. }
      Line^.Handlers[Line^.Count] := Handler;
      Line^.Contexts[Line^.Count] := Context;
      FullMemoryBarrier;
      Inc(Line^.Count);
      Exit(True);
    end;
  if SharedLineCount = MaximumSharedLines then
    Exit;
  Line := @SharedLines[SharedLineCount];
  Line^.Gsi := Gsi;
  Line^.LevelTriggered := LevelTriggered;
  Line^.ActiveLow := ActiveLow;
  Line^.Handlers[0] := Handler;
  Line^.Contexts[0] := Context;
  Line^.Count := 1;
  if not AllocateVector(@DispatchSharedLine, Line, Vector) then
    Exit;
  Line^.Vector := Vector;
  Target := ChooseTargetProcessor;
  if not RouteDeviceInterrupt(Gsi, Vector, Target^.ApicId, ActiveLow, LevelTriggered) then
  begin
    ReleaseLastVector(Vector);
    Exit;
  end;
  Inc(SharedLineCount);
  ReportConnection('GSI', Gsi, Vector, Target);
  Result := True;
end;

procedure WriteSharedLineSummary;
var
  Index: Integer;
  Line: PSharedLine;
begin
  DebugBeginMessage;
  for Index := 0 to SharedLineCount - 1 do
  begin
    Line := @SharedLines[Index];
    DebugWrite('GSI ');
    DebugWriteDecimal(Line^.Gsi);
    DebugWrite(' on vector 0x');
    DebugWriteHex(Line^.Vector, 2);
    DebugWrite(': ');
    DebugWriteDecimal(Line^.Count);
    DebugWrite(' handlers, fired ');
    DebugWriteDecimal(Line^.StormWatch.Fires);
    DebugWriteLine(' times');
  end;
  DebugEndMessage;
end;

function ConnectMessageInterrupt(Handler: TInterruptHandler; Context: Pointer;
  out Message: TInterruptMessage): Boolean;
var
  Vector: Byte;
  Target: PProcessor;
begin
  Message.Address := 0;
  Message.Data := 0;
  if not AllocateVector(Handler, Context, Vector) then
    Exit(False);
  Target := ChooseTargetProcessor;
  if not ComposeMessageInterrupt(Vector, Target^.ApicId, Message.Address, Message.Data) then
  begin
    ReleaseLastVector(Vector);
    Exit(False);
  end;
  ReportConnection('Message interrupt', -1, Vector, Target);
  Result := True;
end;

end.
