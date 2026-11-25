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
  Telling the firmware what the processor driver can do, and the
  processors' performance states.

  - _OSC with the processor UUID (4077A616-290C-47BE-9EBD-D87058713953),
    revision 1, two DWORDs (status, capabilities), or else the older
    _PDC (a buffer: revision 1, one DWORD, the capabilities): the
    firmware's _CST and _PSS then list states for what the kernel can
    enter (MWAIT C-states, P-states through the performance control
    MSR). It is told on every processor object, before _CST is read
    (many firmwares load their per-processor tables only then).
  - _PSS: Package of Package (core frequency MHz, power mW, transition
    latency us, bus master latency us, control, status), fastest first;
    _PCT: two Generic Register descriptors (control, status), functional
    fixed hardware (IA32_PERF_CTL/STATUS) or I/O ports; _PPC: the index
    of the fastest state the firmware allows now.
  - A processor plugged in (Notify 0 or 1 on its object): _STA says
    whether it is present and enabled, _MAT its MADT entry (a local
    APIC or x2APIC entry: its interrupt controller id and whether it is
    enabled).

  Plain Pascal over the interpreter (tools/AcpiPowerTest runs it).
}
unit Firmware.AcpiProcessorControl;

{$mode objfpc}
{$pointermath on}

interface

uses
  Firmware.AmlNamespace;

const
  MaximumAcpiPerformanceStates = 16;
  { TAcpiPerformanceControl.Space. }
  AcpiControlFixedHardware = $7F;
  AcpiControlSystemIo = $01;

type
  TAcpiPerformanceState = record
    FrequencyMegahertz: LongWord;
    PowerMilliwatts: LongWord;
    LatencyMicroseconds: LongWord;
    BusMasterLatencyMicroseconds: LongWord;
    Control: LongWord;
    Status: LongWord;
  end;

  TAcpiPerformanceRegister = record
    Space: Byte;
    BitWidth: Byte;
    Address: QWord;
  end;

  TAcpiPerformance = record
    States: array[0..MaximumAcpiPerformanceStates - 1] of TAcpiPerformanceState;
    Count: Integer;
    Control: TAcpiPerformanceRegister;
    StatusRegister: TAcpiPerformanceRegister;
    { _PPC: the fastest state allowed now (0: all). }
    FastestAllowed: Integer;
  end;

  { How the firmware was told. }
  TProcessorCapabilityMethod = (CapabilitiesNotTold, CapabilitiesByOsc, CapabilitiesByPdc);

{ Tells Processor's firmware Capabilities (_OSC, else _PDC). }
function TellProcessorCapabilities(Processor: PAmlNode; Capabilities: LongWord): TProcessorCapabilityMethod;
{ Processor's _PSS and _PCT (and _PPC); False without both. }
function ReadAcpiPerformance(Processor: PAmlNode; out Performance: TAcpiPerformance): Boolean;
{ _PPC again (after a Notify 0x80 on the processor). }
function ReadFastestAllowedState(Processor: PAmlNode): Integer;
{ True if Node is a processor object (Processor, or a device ACPI0007). }
function IsAcpiProcessor(Node: PAmlNode): Boolean;
{ _STA: present and enabled (no _STA: both). }
function AcpiProcessorIsPresent(Processor: PAmlNode): Boolean;
{ _MAT's interrupt controller id (local APIC or x2APIC entry) and its
  enabled flag; False without a usable _MAT. }
function ReadProcessorInterruptId(Processor: PAmlNode; out ApicId: LongWord; out Enabled: Boolean): Boolean;

implementation

uses
  Runtime.Memory,
  Firmware.AmlValues,
  Firmware.AmlInterpreter,
  Firmware.AcpiDeviceIds,
  Firmware.AcpiDeviceWalk;

const
  GenericRegisterTag = $82;
  ProcessorUuid: array[0..15] of Byte = (
    $16, $A6, $77, $40, $0C, $29, $BE, $47, $9E, $BD, $D8, $70, $58, $71, $39, $53);
  OscRevision = 1;
  PdcRevision = 1;
  { _OSC's status DWORD: an error in bits 1-3. }
  OscErrorMask = $0E;

function TellByOsc(Processor: PAmlNode; Capabilities: LongWord): Boolean;
var
  Arguments: array[0..3] of TAmlValue;
  Result_: TAmlValue;
  Words: PLongWord;
begin
  Result := False;
  if FindChild(Processor, SegmentOf('_OSC')) = nil then
    Exit;
  Arguments[0] := MakeBufferFrom(@ProcessorUuid[0], SizeOf(ProcessorUuid));
  Arguments[1] := MakeInteger(OscRevision);
  Arguments[2] := MakeInteger(2);
  Arguments[3] := MakeBuffer(8);
  if (Arguments[0].Kind = AmlBuffer) and (Arguments[3].Kind = AmlBuffer) then
  begin
    Words := PLongWord(ValueData(Arguments[3]));
    Words[0] := 0;
    Words[1] := Capabilities;
    if EvaluatePath(Processor, '_OSC', @Arguments[0], 4, Result_) then
    begin
      Result := (Result_.Kind <> AmlBuffer) or (ValueLength(Result_) < 4) or
        ((PLongWord(ValueData(Result_))^ and OscErrorMask) = 0);
      ReleaseValue(Result_);
    end;
  end;
  ReleaseValue(Arguments[0]);
  ReleaseValue(Arguments[3]);
end;

function TellByPdc(Processor: PAmlNode; Capabilities: LongWord): Boolean;
var
  Argument: TAmlValue;
  Ignored: TAmlValue;
  Words: PLongWord;
begin
  Result := False;
  if FindChild(Processor, SegmentOf('_PDC')) = nil then
    Exit;
  Argument := MakeBuffer(12);
  if Argument.Kind <> AmlBuffer then
    Exit;
  Words := PLongWord(ValueData(Argument));
  Words[0] := PdcRevision;
  Words[1] := 1;
  Words[2] := Capabilities;
  Result := EvaluatePath(Processor, '_PDC', @Argument, 1, Ignored);
  if Result then
    ReleaseValue(Ignored);
  ReleaseValue(Argument);
end;

function TellProcessorCapabilities(Processor: PAmlNode; Capabilities: LongWord): TProcessorCapabilityMethod;
begin
  Result := CapabilitiesNotTold;
  if Processor = nil then
    Exit;
  if TellByOsc(Processor, Capabilities) then
    Result := CapabilitiesByOsc
  else if TellByPdc(Processor, Capabilities) then
    Result := CapabilitiesByPdc;
end;

function ElementNumber(const Package: TAmlValue; Index: LongWord): LongWord;
var
  Number: QWord;
begin
  Result := 0;
  if (Package.Kind = AmlPackage) and (Index < Package.Package^.Count) and
     ValueToInteger(Package.Package^.Elements[Index], True, Number) then
    Result := LongWord(Number);
end;

function ReadRegister(const Value: TAmlValue; out Register: TAcpiPerformanceRegister): Boolean;
var
  Data: PByte;
begin
  ZeroMemory(@Register, SizeOf(Register));
  Result := (Value.Kind = AmlBuffer) and (ValueLength(Value) >= 15);
  if not Result then
    Exit;
  Data := ValueData(Value);
  Result := Data[0] = GenericRegisterTag;
  if not Result then
    Exit;
  Register.Space := Data[3];
  Register.BitWidth := Data[4];
  Register.Address := PQWord(@Data[7])^;
  Result := Register.Space in [AcpiControlFixedHardware, AcpiControlSystemIo];
end;

function ReadControlRegisters(Processor: PAmlNode; var Performance: TAcpiPerformance): Boolean;
var
  Value: TAmlValue;
begin
  Result := False;
  if not EvaluateChild(Processor, '_PCT', Value) then
    Exit;
  Result := (Value.Kind = AmlPackage) and (Value.Package^.Count >= 2) and
    ReadRegister(Value.Package^.Elements[0], Performance.Control) and
    ReadRegister(Value.Package^.Elements[1], Performance.StatusRegister);
  ReleaseValue(Value);
end;

function ReadStates(Processor: PAmlNode; var Performance: TAcpiPerformance): Boolean;
var
  Value: TAmlValue;
  Index: LongWord;
  Entry: PAmlValue;
  State: ^TAcpiPerformanceState;
begin
  Result := False;
  if not EvaluateChild(Processor, '_PSS', Value) then
    Exit;
  if Value.Kind = AmlPackage then
  begin
    Index := 0;
    while (Index < Value.Package^.Count) and (Performance.Count < MaximumAcpiPerformanceStates) do
    begin
      Entry := @Value.Package^.Elements[Index];
      if (Entry^.Kind = AmlPackage) and (Entry^.Package^.Count >= 6) then
      begin
        State := @Performance.States[Performance.Count];
        State^.FrequencyMegahertz := ElementNumber(Entry^, 0);
        State^.PowerMilliwatts := ElementNumber(Entry^, 1);
        State^.LatencyMicroseconds := ElementNumber(Entry^, 2);
        State^.BusMasterLatencyMicroseconds := ElementNumber(Entry^, 3);
        State^.Control := ElementNumber(Entry^, 4);
        State^.Status := ElementNumber(Entry^, 5);
        if State^.FrequencyMegahertz > 0 then
          Inc(Performance.Count);
      end;
      Inc(Index);
    end;
  end;
  ReleaseValue(Value);
  Result := Performance.Count > 0;
end;

function ReadFastestAllowedState(Processor: PAmlNode): Integer;
var
  Value: QWord;
begin
  Value := ChildInteger(Processor, '_PPC', 0);
  if Value >= MaximumAcpiPerformanceStates then
    Value := 0;
  Result := Integer(Value);
end;

function ReadAcpiPerformance(Processor: PAmlNode; out Performance: TAcpiPerformance): Boolean;
begin
  ZeroMemory(@Performance, SizeOf(Performance));
  Result := (Processor <> nil) and ReadStates(Processor, Performance) and
    ReadControlRegisters(Processor, Performance);
  if not Result then
  begin
    Performance.Count := 0;
    Exit;
  end;
  Performance.FastestAllowed := ReadFastestAllowedState(Processor);
  if Performance.FastestAllowed >= Performance.Count then
    Performance.FastestAllowed := Performance.Count - 1;
end;

function IsAcpiProcessor(Node: PAmlNode): Boolean;
begin
  Result := (Node <> nil) and ((Node^.Kind = NodeProcessor) or
    ((Node^.Kind = NodeDevice) and DeviceHasId(Node, 'ACPI0007')));
end;

function AcpiProcessorIsPresent(Processor: PAmlNode): Boolean;
const
  StatusPresentAndEnabled = 3;
begin
  Result := (ChildInteger(Processor, '_STA', StatusPresentAndEnabled) and StatusPresentAndEnabled) =
    StatusPresentAndEnabled;
end;

function ReadProcessorInterruptId(Processor: PAmlNode; out ApicId: LongWord; out Enabled: Boolean): Boolean;
const
  EntryLocalApic = 0;
  EntryX2Apic = 9;
  LocalApicLength = 8;
  X2ApicLength = 16;
  EntryEnabled = 1;
var
  Value: TAmlValue;
  Data: PByte;
  Length: LongWord;
begin
  ApicId := 0;
  Enabled := False;
  Result := False;
  if (Processor = nil) or not EvaluateChild(Processor, '_MAT', Value) then
    Exit;
  if Value.Kind = AmlBuffer then
  begin
    Data := ValueData(Value);
    Length := ValueLength(Value);
    if (Length >= LocalApicLength) and (Data[0] = EntryLocalApic) and (Data[1] >= LocalApicLength) then
    begin
      ApicId := Data[3];
      Enabled := (PLongWord(@Data[4])^ and EntryEnabled) <> 0;
      Result := True;
    end
    else if (Length >= X2ApicLength) and (Data[0] = EntryX2Apic) and (Data[1] >= X2ApicLength) then
    begin
      ApicId := PLongWord(@Data[4])^;
      Enabled := (PLongWord(@Data[8])^ and EntryEnabled) <> 0;
      Result := True;
    end;
  end;
  ReleaseValue(Value);
end;

end.
