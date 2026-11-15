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
  ACPI events: the power and sleep buttons and general purpose events.

  Every ACPI event raises the SCI (Io.AcpiHardware). Its handler reads
  the fixed events' status: the power and sleep buttons are cleared and
  noted; each general purpose event that fired is disabled (it may be
  level triggered) and noted. Then a deferred call wakes the event
  thread (RunAcpiEvents), which does what may take long or run AML:
  - a GPE runs its handler method, \_GPE._Lnn (level: then its status is
    cleared) or _Enn (edge: cleared first), and is enabled again;
  - a button press goes to the power policy (the handler the kernel
    gave), and so does a Notify of 0x80 to a power or sleep button
    device (PNP0C0C, PNP0C0E: buttons with control methods); other
    notifications are logged.

  The SCI is the ISA IRQ the FADT names, routed through the MADT's
  overrides; without one it is level triggered, active low (ACPI's
  rule). It may be shared.
}
unit Io.AcpiEvents;

{$mode objfpc}
{$pointermath on}

interface

type
  TPowerEvent = (PowerEventPowerButton, PowerEventSleepButton);
  TPowerEventHandler = procedure(Event: TPowerEvent);

{ After the namespace is loaded: ACPI mode, the SCI, the buttons and the
  GPEs that have methods. False if there is no ACPI fixed hardware. }
function InitializeAcpiEvents(Handler: TPowerEventHandler): Boolean;
{ The event thread (it runs AML: give it a large stack). }
procedure RunAcpiEvents(Context: Pointer);

implementation

uses
  Runtime.Atomic,
  Kernel.Arch.TrapFrame,
  Kernel.DeferredCalls,
  Kernel.Events,
  Firmware.Madt,
  Firmware.AmlHost,
  Firmware.AmlValues,
  Firmware.AmlNamespace,
  Firmware.AmlInterpreter,
  Firmware.AcpiDeviceIds,
  Firmware.AcpiSleepStates,
  Io.AcpiHardware,
  Io.AcpiNamespace,
  Io.InterruptRouting,
  Io.PowerManagement,
  Io.AcpiSleep,
  Debug.Output;

const
  MaximumGpes = 256;
  { Notify values. }
  NotifyButtonPressed = $80;

var
  PowerPolicy: TPowerEventHandler;
  WakeCall: TDeferredCall;
  WorkArrived: TEvent;
  { Noted by the SCI's handler, taken by the event thread. }
  PendingFixed: PtrUInt;
  PendingGpes: array[0..MaximumGpes div 64 - 1] of PtrUInt;
  { GPEs with a handler method (only those are ever enabled). }
  HandledGpes: array[0..MaximumGpes div 32 - 1] of LongWord;
  GpeCount: LongWord;
  { Button presses that came as Notify while AML ran. }
  NotifiedButtons: PtrUInt;

{ --- The SCI -------------------------------------------------------------------- }

procedure HandleSci(Frame: PTrapFrame; Context: Pointer);
var
  Status: Word;
  Number: LongWord;
  Noticed: Boolean;
begin
  Noticed := False;
  Status := ReadPm1Status and ReadPm1Enable and (Pm1PowerButton or Pm1SleepButton);
  if Status <> 0 then
  begin
    ClearPm1Status(Status);
    AtomicOr(PendingFixed, Status);
    Noticed := True;
  end;
  if GpeCount > 0 then
    for Number := 0 to GpeCount - 1 do
    if ((HandledGpes[Number div 32] and (LongWord(1) shl (Number mod 32))) <> 0) and GpeIsEnabled(Number) and
       GpeIsSet(Number) then
    begin
      { Off until its method has run: a level triggered one would fire
        again at once. }
      EnableGpe(Number, False);
      AtomicOr(PendingGpes[Number div 64], PtrUInt(1) shl (Number mod 64));
      Noticed := True;
    end;
  if Noticed then
    QueueDeferredCall(WakeCall);
end;

procedure WakeEventThread(Context: Pointer);
begin
  SignalEvent(WorkArrived);
end;

{ --- Notify ------------------------------------------------------------------------ }

procedure HandleNotify(Node: Pointer; Value: QWord);
var
  Path: array[0..79] of Char;
begin
  if Value = NotifyButtonPressed then
  begin
    if DeviceHasId(PAmlNode(Node), 'PNP0C0C') then
    begin
      AtomicOr(NotifiedButtons, Pm1PowerButton);
      Exit;
    end;
    if DeviceHasId(PAmlNode(Node), 'PNP0C0E') then
    begin
      AtomicOr(NotifiedButtons, Pm1SleepButton);
      Exit;
    end;
  end;
  NodePathText(PAmlNode(Node), @Path[0], SizeOf(Path));
  DebugBeginMessage;
  DebugWriteTag('acpi');
  DebugWrite('notify ');
  DebugWrite(@Path[0]);
  DebugWrite(' 0x');
  DebugWriteHex(Value, 2);
  DebugWriteLine('');
  DebugEndMessage;
end;

{ --- The event thread ------------------------------------------------------------- }

procedure RunGpeMethod(Number: LongWord);
var
  Method: PAmlNode;
  LevelTriggered: Boolean;
  Ignored: TAmlValue;
begin
  Method := GpeMethodOf(Number, LevelTriggered);
  if not LevelTriggered then
    ClearGpe(Number);
  if Method <> nil then
  begin
    LockAmlInterpreter;
    if EvaluateNode(Method, nil, 0, Ignored) then
      ReleaseValue(Ignored);
    UnlockAmlInterpreter;
  end;
  if LevelTriggered then
    ClearGpe(Number);
  EnableGpe(Number, True);
end;

procedure ReportButton(Bits: PtrUInt);
begin
  if (Bits and Pm1PowerButton) <> 0 then
  begin
    DebugBeginMessage;
    DebugWriteTag('acpi');
    DebugWriteLine('power button pressed');
    DebugEndMessage;
    PowerPolicy(PowerEventPowerButton);
  end;
  if (Bits and Pm1SleepButton) <> 0 then
  begin
    DebugBeginMessage;
    DebugWriteTag('acpi');
    DebugWriteLine('sleep button pressed');
    DebugEndMessage;
    PowerPolicy(PowerEventSleepButton);
  end;
end;

procedure RunAcpiEvents(Context: Pointer);
var
  Index: Integer;
  Bits: PtrUInt;
  Bit: Integer;
begin
  while True do
  begin
    WaitForEvent(WorkArrived);
    for Index := 0 to High(PendingGpes) do
    begin
      Bits := AtomicExchange(PendingGpes[Index], 0);
      for Bit := 0 to 63 do
        if (Bits and (PtrUInt(1) shl Bit)) <> 0 then
          RunGpeMethod(LongWord(Index) * 64 + LongWord(Bit));
    end;
    ReportButton(AtomicExchange(PendingFixed, 0) or AtomicExchange(NotifiedButtons, 0));
  end;
end;

{ --- Setting up ------------------------------------------------------------------- }

function ConnectSci: Boolean;
var
  Irq: Byte;
  Routing: TIsaInterruptRouting;
begin
  Irq := Byte(AcpiHardware.SciInterrupt);
  if IsaInterruptIsOverridden(Irq) then
  begin
    Routing := RoutingOfIsaInterrupt(Irq);
    Result := ConnectGlobalInterrupt(Routing.GlobalInterrupt, Routing.LevelTriggered, Routing.ActiveLow,
      @HandleSci, nil);
  end
  else
    Result := ConnectGlobalInterrupt(Irq, True, True, @HandleSci, nil);
end;

{ Every GPE off and cleared; those with a method on. }
function EnableHandledGpes: Integer;
var
  Number: LongWord;
  LevelTriggered: Boolean;
begin
  Result := 0;
  GpeCount := AcpiHardware.GpeCount;
  if GpeCount > MaximumGpes then
    GpeCount := MaximumGpes;
  if GpeCount = 0 then
    Exit;
  for Number := 0 to GpeCount - 1 do
  begin
    EnableGpe(Number, False);
    ClearGpe(Number);
    if GpeMethodOf(Number, LevelTriggered) <> nil then
    begin
      HandledGpes[Number div 32] := HandledGpes[Number div 32] or (LongWord(1) shl (Number mod 32));
      EnableGpe(Number, True);
      Inc(Result);
    end;
  end;
end;

procedure ReportEvents(Gpes: Integer);
begin
  DebugBeginMessage;
  DebugWriteTag('acpi');
  DebugWrite('events: SCI on IRQ ');
  DebugWriteDecimal(AcpiHardware.SciInterrupt);
  if AcpiHardware.FixedPowerButton then
    DebugWrite(', power button');
  if AcpiHardware.FixedSleepButton then
    DebugWrite(', sleep button');
  DebugWrite(', ');
  DebugWriteDecimal(Gpes);
  DebugWriteLine(' GPEs with methods');
  DebugEndMessage;
end;

{ The enables of the buttons and handled GPEs, as set up. }
var
  EnabledFixed: Word;

procedure WriteEnables;
var
  Number: LongWord;
begin
  WritePm1Enable(0);
  ClearPm1Status(Pm1StatusBits);
  if GpeCount > 0 then
    for Number := 0 to GpeCount - 1 do
    begin
      EnableGpe(Number, False);
      ClearGpe(Number);
      if (HandledGpes[Number div 32] and (LongWord(1) shl (Number mod 32))) <> 0 then
        EnableGpe(Number, True);
    end;
  WritePm1Enable(EnabledFixed);
end;

{ After suspend to RAM: ACPI mode and \_WAK, then the enables again
  (the hardware was reset). }
procedure ResumeAcpi(Context: Pointer);
begin
  FinishResumeFromRam;
  WriteEnables;
end;

function InitializeAcpiEvents(Handler: TPowerEventHandler): Boolean;
var
  Enabled: Word;
  Gpes: Integer;
begin
  Result := False;
  if not AcpiNamespaceIsLoaded or not InitializeAcpiHardware or not EnableAcpiMode then
    Exit;
  PowerPolicy := Handler;
  InitializeEvent(WorkArrived, EventKindSynchronization, False);
  InitializeDeferredCall(WakeCall, @WakeEventThread, nil);
  { Fixed events off and cleared, then the buttons on. }
  WritePm1Enable(0);
  ClearPm1Status(Pm1StatusBits);
  LockAmlInterpreter;
  Gpes := EnableHandledGpes;
  AmlHost.Notify := @HandleNotify;
  UnlockAmlInterpreter;
  if not ConnectSci then
    Exit;
  Enabled := 0;
  if AcpiHardware.FixedPowerButton then
    Enabled := Enabled or Pm1PowerButton;
  if AcpiHardware.FixedSleepButton then
    Enabled := Enabled or Pm1SleepButton;
  WritePm1Enable(Enabled);
  EnabledFixed := Enabled;
  RegisterPowerHandler('ACPI', PowerStageFirmware, nil, @ResumeAcpi, nil);
  ReportEvents(Gpes);
  Result := True;
end;

end.
