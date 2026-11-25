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
  AmlTest: runs the kernel's AML interpreter on the host, against a
  captured DSDT, and prints what it found.

    AmlTest TABLE.aml

  The table is loaded into a fresh namespace, its devices initialized,
  and the PCI interrupt routing built (APIC mode). Then, in PIC mode,
  the four LNKx link devices of a QEMU q35 table are asked for their
  current interrupt: their _CRS methods read the PIRQ routing registers
  through a PCI configuration region, which here is a fake
  configuration space with those registers set (q35's LPC bridge,
  device 31: A-D 10, 10, 11, 11 and E-H 5, 7, 9, 11; i440fx's PIIX,
  device 1: A-D 10, 10, 11, 11) and everything else reading as all ones.

  Then the sleep states the table offers (their SLP_TYP values), the
  general purpose events that have handler methods, and the power
  button devices; and Notify is logged as the interpreter makes it.

  Last, a small table of its own (hand assembled) runs operators the
  QEMU tables do not reach at boot: string concatenation, a buffer in
  hexadecimal, a store to the Debug object.

  The output is compared with the expected one by "make aml-test".

    AmlTest --malformed FOLDER

  Runs the malformed tables tools/AmlTest/make-malformed.py writes (huge
  and misplaced buffer fields, a reference to itself, a package stored
  into itself, operators nested 600 deep, calls that double at every
  level, fields past their region or over missing names, a chain of 200
  index fields): each method must fail, nothing may crash, hang or write
  outside its blocks.
}
program AmlTest;

{$mode objfpc}
{$pointermath on}

uses
  Firmware.AmlHost,
  Firmware.AmlValues,
  Firmware.AmlNamespace,
  Firmware.AmlInterpreter,
  Firmware.AcpiResources,
  Firmware.AcpiDeviceIds,
  Firmware.AcpiSleepStates,
  Firmware.AcpiPciRouting;

var
  { Bus 0's configuration space: 32 devices, 8 functions, 256 bytes. }
  Configuration: array[0..31, 0..7, 0..255] of Byte;

{ --- The host ------------------------------------------------------------------ }

{ Every block has a guard on both sides, checked when it is freed and
  at the end of the malformed tables: the interpreter must not write
  outside what it allocated. }
const
  GuardBytes = 32;
  GuardByte = $A5;

var
  GuardFailures: Integer = 0;
  LiveBlocks: Integer = 0;

function GuardsAreIntact(Start: PByte): Boolean;
var
  Size: PtrUInt;
  Index: Integer;
begin
  Size := PPtrUInt(Start)^;
  Result := True;
  for Index := 0 to GuardBytes - 1 do
    if (Start[SizeOf(PtrUInt) + Index] <> GuardByte) or
       (Start[SizeOf(PtrUInt) + GuardBytes + Size + Index] <> GuardByte) then
      Result := False;
end;

function HostAllocate(ByteCount: PtrUInt): Pointer;
var
  Start: PByte;
begin
  { As the kernel heap would: a request of gigabytes fails. }
  if ByteCount > 256 * 1024 * 1024 then
    Exit(nil);
  Start := AllocMem(SizeOf(PtrUInt) + 2 * GuardBytes + ByteCount);
  PPtrUInt(Start)^ := ByteCount;
  FillChar(Start[SizeOf(PtrUInt)], GuardBytes, GuardByte);
  FillChar(Start[SizeOf(PtrUInt) + GuardBytes + ByteCount], GuardBytes, GuardByte);
  Inc(LiveBlocks);
  Result := Start + SizeOf(PtrUInt) + GuardBytes;
end;

procedure HostFree(Block: Pointer);
var
  Start: PByte;
begin
  if Block = nil then
    Exit;
  Start := PByte(Block) - GuardBytes - SizeOf(PtrUInt);
  if not GuardsAreIntact(Start) then
  begin
    WriteLn('FAIL a block of ', PPtrUInt(Start)^, ' bytes was written outside its bounds');
    Inc(GuardFailures);
  end;
  Dec(LiveBlocks);
  FreeMem(Start);
end;

function ConfigurationByte(Address: QWord; Offset: Integer; out Location: PByte): Boolean;
var
  Bus: Byte;
  Device: Byte;
  FunctionNumber: Byte;
  Register: LongWord;
begin
  Bus := Byte(Address shr 40);
  Device := Byte(Address shr 32);
  FunctionNumber := Byte(Address shr 24);
  Register := (Address and $FFFFFF) + LongWord(Offset);
  Result := (Bus = 0) and (Device < 32) and (FunctionNumber < 8) and (Register < 256);
  if Result then
    Location := @Configuration[Device, FunctionNumber, Register];
end;

function HostRead(Space: Byte; Address: QWord; Width: Byte; out Value: QWord): Boolean;
var
  Index: Integer;
  Location: PByte;
begin
  Value := 0;
  Result := True;
  if Space <> AmlSpacePciConfiguration then
    Exit;
  for Index := Width div 8 - 1 downto 0 do
    if ConfigurationByte(Address, Index, Location) then
      Value := (Value shl 8) or Location^
    else
      Value := (Value shl 8) or $FF;
end;

function HostWrite(Space: Byte; Address: QWord; Width: Byte; Value: QWord): Boolean;
var
  Index: Integer;
  Location: PByte;
begin
  Result := True;
  if Space <> AmlSpacePciConfiguration then
    Exit;
  for Index := 0 to Width div 8 - 1 do
    if ConfigurationByte(Address, Index, Location) then
      Location^ := Byte(Value shr (Index * 8));
end;

procedure HostSleep(Milliseconds: QWord);
begin
end;

procedure HostStall(Microseconds: QWord);
begin
end;

function HostTimer: QWord;
begin
  Result := 0;
end;

procedure HostLog(Text: PChar);
begin
  WriteLn('log: ', Text);
end;

procedure HostNotify(Node: Pointer; Value: QWord);
var
  Path: array[0..79] of Char;
begin
  NodePathText(PAmlNode(Node), @Path[0], SizeOf(Path));
  WriteLn('notify ', PChar(@Path[0]), ' ', Value);
end;

procedure SetUpHost;
const
  { The PIRQ routing registers of the q35 LPC bridge and the PIIX. }
  LpcDevice = $1F;
  PiixDevice = 1;
  PirqLow: array[0..3] of Byte = (10, 10, 11, 11);
  PirqHigh: array[0..3] of Byte = (5, 7, 9, 11);
var
  Index: Integer;
begin
  FillChar(Configuration, SizeOf(Configuration), $FF);
  for Index := 0 to 3 do
  begin
    Configuration[LpcDevice, 0, $60 + Index] := PirqLow[Index];
    Configuration[LpcDevice, 0, $68 + Index] := PirqHigh[Index];
    Configuration[PiixDevice, 0, $60 + Index] := PirqLow[Index];
  end;
  AmlHost.Allocate := @HostAllocate;
  AmlHost.Free := @HostFree;
  AmlHost.ReadSpace := @HostRead;
  AmlHost.WriteSpace := @HostWrite;
  AmlHost.Sleep := @HostSleep;
  AmlHost.Stall := @HostStall;
  AmlHost.Timer := @HostTimer;
  AmlHost.Log := @HostLog;
  AmlHost.Notify := @HostNotify;
end;

{ --- The checks -------------------------------------------------------------------- }

function LoadTable(Path: string): PByte;
var
  TableFile: file of Byte;
  Size: Int64;
begin
  Assign(TableFile, Path);
  Reset(TableFile);
  Size := FileSize(TableFile);
  Result := AllocMem(Size);
  BlockRead(TableFile, Result^, Size);
  Close(TableFile);
end;

procedure ShowRoutes;
const
  Pins: array[0..3] of Char = 'ABCD';
  Triggers: array[Boolean] of string = ('edge', 'level');
  Kinds: array[Boolean] of string = ('GSI', 'IRQ');
  Polarities: array[Boolean] of string = ('high', 'low');
var
  Index: Integer;
  Route: PPciRoute;
begin
  for Index := 0 to PciRouteCount - 1 do
  begin
    Route := PciRouteAt(Index);
    WriteLn('route ', Route^.Bus, ':', Route^.Device, ' INT', Pins[Route^.Pin], ' -> ', Kinds[Route^.IsaInterrupt], ' ',
      Route^.GlobalInterrupt, ' ', Triggers[Route^.LevelTriggered], ' ', Polarities[Route^.ActiveLow]);
  end;
end;

procedure ShowLinksInPicMode;
const
  Links: array[0..3] of PChar = ('\_SB_.LNKA', '\_SB_.LNKB', '\_SB_.LNKC', '\_SB_.LNKD');
var
  Mode: TAmlValue;
  Ignored: TAmlValue;
  Resources: TAmlValue;
  Resource: TInterruptResource;
  Index: Integer;
  Link: PAmlNode;
begin
  Mode := MakeInteger(0);
  if EvaluatePath(nil, '\_PIC', @Mode, 1, Ignored) then
    ReleaseValue(Ignored);
  for Index := 0 to High(Links) do
  begin
    Link := LookupText(NamespaceRoot, Links[Index]);
    if (Link <> nil) and EvaluatePath(Link, '_CRS', nil, 0, Resources) and (Resources.Kind = AmlBuffer) and
       FindInterruptResource(Resources.Bytes^.Data, Resources.Bytes^.Length, Resource) and (Resource.Count > 0) then
      WriteLn('pic ', Links[Index], ' -> IRQ ', Resource.Interrupts[0])
    else
      WriteLn('pic ', Links[Index], ' -> none');
    ReleaseValue(Resources);
  end;
  { The table _PRT gives in PIC mode names the LNKx links. }
  if EvaluatePath(nil, '\_SB_.PCI0._PRT', nil, 0, Resources) and (Resources.Kind = AmlPackage) then
    WriteLn('pic _PRT entries: ', Resources.Package^.Count)
  else
    WriteLn('pic _PRT: none');
  ReleaseValue(Resources);
end;

procedure ShowSleepStates;
var
  State: Integer;
  TypeA: Byte;
  TypeB: Byte;
begin
  for State := 0 to 5 do
    if SleepTypeOf(State, TypeA, TypeB) then
      WriteLn('sleep S', State, ': SLP_TYP ', TypeA, ' ', TypeB);
end;

procedure ShowGpes;
var
  Number: LongWord;
  Level: Boolean;
begin
  for Number := 0 to 255 do
    if GpeMethodOf(Number, Level) <> nil then
      WriteLn('gpe ', Number, ' level ', Level);
end;

procedure ShowButton(Node: PAmlNode; Context: Pointer);
var
  Path: array[0..79] of Char;
begin
  if DeviceHasId(Node, 'PNP0C0C') or DeviceHasId(Node, 'PNP0C0E') then
  begin
    NodePathText(Node, @Path[0], SizeOf(Path));
    WriteLn('button ', PChar(@Path[0]));
  end;
end;

const
  { An SSDT: Method (TST1) { Return (Concatenate ("ab", ToHexString
    (Buffer (2) {1, 2}))) } and Method (TST2) { Store ("hi", Debug)
    Return (One) }. Integers are 64-bit (revision 2). }
  OperatorTable: array[0..36 + 22 + 16 - 1] of Byte = (
    Ord('S'), Ord('S'), Ord('D'), Ord('T'), 74, 0, 0, 0, 2, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    $14, $15, Ord('T'), Ord('S'), Ord('T'), Ord('1'), $00,
    $A4, $73, $0D, Ord('a'), Ord('b'), $00, $98, $11, $05, $0A, $02, $01, $02, $00, $00,
    $14, $0F, Ord('T'), Ord('S'), Ord('T'), Ord('2'), $00,
    $70, $0D, Ord('h'), Ord('i'), $00, $5B, $31, $A4, $01);

procedure RunOperatorTable;
var
  Value: TAmlValue;
begin
  if not LoadAmlTable(@OperatorTable[0]) then
    WriteLn('operators: load failed');
  if EvaluatePath(nil, '\TST1', nil, 0, Value) and (Value.Kind = AmlString) then
    WriteLn('operators: ', PChar(Value.Bytes^.Data))
  else
    WriteLn('operators: TST1 failed');
  ReleaseValue(Value);
  if EvaluatePath(nil, '\TST2', nil, 0, Value) and (Value.Kind = AmlInteger) then
    WriteLn('operators: TST2 ', Value.Integer)
  else
    WriteLn('operators: TST2 failed');
  ReleaseValue(Value);
end;

{ AmlTest --malformed FOLDER: the tables make-malformed.py wrote, listed
  in FOLDER/CASES; table N defines method \TNNN, which must fail.
  Nothing may crash or write outside its blocks. }
procedure RunMalformedTables(const Folder: string);
var
  Cases: Text;
  CaseName: string;
  Number: Integer;
  Failures: Integer;
  MethodPath: array[0..7] of Char;
  NumberText: string;
  Value: TAmlValue;
  Succeeded: Boolean;
begin
  Assign(Cases, Folder + '/CASES');
  Reset(Cases);
  Number := 0;
  Failures := 0;
  while not Eof(Cases) do
  begin
    ReadLn(Cases, CaseName);
    if CaseName = '' then
      Continue;
    Inc(Number);
    LoadAmlTable(LoadTable(Folder + '/' + CaseName + '.aml'));
    Str(1000 + Number, NumberText);
    MethodPath := '\T' + Copy(NumberText, 2, 3);
    Succeeded := EvaluatePath(nil, @MethodPath[0], nil, 0, Value);
    ReleaseValue(Value);
    if Succeeded then
    begin
      WriteLn('FAIL ', CaseName, ': ', MethodPath, ' ran to its end');
      Inc(Failures);
    end;
  end;
  Close(Cases);
  Failures := Failures + GuardFailures;
  if Failures > 0 then
  begin
    WriteLn('AML MALFORMED TEST FAILED: ', Failures);
    Halt(1);
  end;
  WriteLn('AML MALFORMED TEST PASSED: ', Number, ' tables');
end;

var
  Table: PByte;
begin
  if (ParamCount = 2) and (ParamStr(1) = '--malformed') then
  begin
    SetUpHost;
    AmlHost.Log := nil;
    RunMalformedTables(ParamStr(2));
    Halt(0);
  end;
  if ParamCount <> 1 then
  begin
    WriteLn('usage: AmlTest TABLE.aml | --malformed FOLDER');
    Halt(2);
  end;
  SetUpHost;
  Table := LoadTable(ParamStr(1));
  if not LoadAmlTable(Table) then
    WriteLn('load: failed');
  WriteLn('nodes: ', CountNodes);
  InitializeAmlDevices;
  WriteLn('routes: ', BuildPciRouting);
  ShowRoutes;
  ShowLinksInPicMode;
  ShowSleepStates;
  ShowGpes;
  VisitNodes(NamespaceRoot, @ShowButton, nil);
  RunOperatorTable;
end.
