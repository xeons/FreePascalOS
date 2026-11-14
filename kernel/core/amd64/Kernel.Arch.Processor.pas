{
  Boot processor setup for x86-64: descriptor tables, interrupt table,
  floating point and SIMD control, and processor identification.

  The secondary processors start with the boot processor's CR0 and CR4
  (Kernel.Arch.ProcessorStartup), so what is set here holds for all.
}
unit Kernel.Arch.Processor;

{$mode objfpc}

interface

procedure InitializeBootProcessor;
procedure WriteProcessorDescription;

{ The initial APIC id of the executing processor, from CPUID. }
function ReadInitialApicId: LongWord;

implementation

uses
  Runtime.Text,
  Kernel.Arch.Cpu,
  Kernel.Arch.DescriptorTables,
  Kernel.Arch.InterruptTable,
  Kernel.Arch.ProcessorBlock,
  Kernel.Processors,
  Debug.Output;

const
  CpuidVendor = 0;
  CpuidBrandStringFirst = $80000002;
  CpuidBrandStringLast = $80000004;
  CpuidHighestExtendedLeaf = $80000000;

  BrandStringLength = 48;

function ReadInitialApicId: LongWord;
var
  Registers: TCpuidResult;
begin
  ExecuteCpuid(0, 0, Registers);
  if Registers.Eax >= $B then
  begin
    { Leaf 0Bh reports the full 32-bit (x2APIC) id. }
    ExecuteCpuid($B, 0, Registers);
    if Registers.Ebx <> 0 then
      Exit(Registers.Edx);
  end;
  ExecuteCpuid(1, 0, Registers);
  Result := Registers.Ebx shr 24;
end;

const
  { FXSAVE/FXRSTOR and SSE instructions are allowed; unmasked SIMD
    floating point exceptions raise #XM (without this bit they would
    raise #UD, so programs could not tell a division by zero from an
    invalid instruction). }
  Cr4OsFxsr = QWord(1) shl 9;
  Cr4OsXmmExceptions = QWord(1) shl 10;
  { x87: unmasked exceptions raise #MF (native error reporting) instead
    of signalling the legacy FERR# line nobody listens to; WAIT checks
    for them; no emulation. }
  Cr0MonitorCoprocessor = QWord(1) shl 1;
  Cr0Emulation = QWord(1) shl 2;
  Cr0NumericError = QWord(1) shl 5;

{ Floating point exceptions a program leaves unmasked reach it as #MF
  (x87) and #XM (SSE), which the kernel passes on
  (Processes.UserExceptions). }
procedure EnableFloatingPointExceptions;
begin
  WriteControlRegister0((ReadControlRegister0 or Cr0MonitorCoprocessor or Cr0NumericError) and
    not Cr0Emulation);
  WriteControlRegister4(ReadControlRegister4 or Cr4OsFxsr or Cr4OsXmmExceptions);
end;

procedure InitializeBootProcessor;
var
  Processor: PProcessor;
begin
  EnableFloatingPointExceptions;
  Processor := InitializeBootProcessorBlock(ReadInitialApicId);
  InitializeBootDescriptorTables(Processor^.DescriptorTables);
  { After the segment registers were reloaded (which clears GS). }
  ArchSetProcessorBlock(Processor);
  MarkProcessorBlocksReady;
  InitializeInterruptTable;
end;

procedure StoreRegister(Value: LongWord; Destination: PChar);
begin
  Destination[0] := Char(Value and $FF);
  Destination[1] := Char((Value shr 8) and $FF);
  Destination[2] := Char((Value shr 16) and $FF);
  Destination[3] := Char((Value shr 24) and $FF);
end;

procedure ReadVendorString(out Vendor: array of Char);
var
  Registers: TCpuidResult;
begin
  ExecuteCpuid(CpuidVendor, 0, Registers);
  { The vendor string is stored in EBX, EDX, ECX order. }
  StoreRegister(Registers.Ebx, @Vendor[0]);
  StoreRegister(Registers.Edx, @Vendor[4]);
  StoreRegister(Registers.Ecx, @Vendor[8]);
  Vendor[12] := #0;
end;

function ReadBrandString(out Brand: array of Char): Boolean;
var
  Registers: TCpuidResult;
  Leaf: LongWord;
  Offset: Integer;
begin
  ExecuteCpuid(CpuidHighestExtendedLeaf, 0, Registers);
  if Registers.Eax < CpuidBrandStringLast then
    Exit(False);

  Offset := 0;
  for Leaf := CpuidBrandStringFirst to CpuidBrandStringLast do
  begin
    ExecuteCpuid(Leaf, 0, Registers);
    StoreRegister(Registers.Eax, @Brand[Offset]);
    StoreRegister(Registers.Ebx, @Brand[Offset + 4]);
    StoreRegister(Registers.Ecx, @Brand[Offset + 8]);
    StoreRegister(Registers.Edx, @Brand[Offset + 12]);
    Offset := Offset + 16;
  end;
  Brand[BrandStringLength] := #0;
  Result := True;
end;

function SkipLeadingSpaces(Text: PChar): PChar;
begin
  Result := Text;
  while Result^ = ' ' do
    Inc(Result);
end;

procedure WriteProcessorDescription;
var
  Vendor: array[0..12] of Char;
  Brand: array[0..BrandStringLength] of Char;
begin
  ReadVendorString(Vendor);

  DebugBeginMessage;
  DebugWriteTag('cpu');
  if ReadBrandString(Brand) then
  begin
    DebugWrite(SkipLeadingSpaces(@Brand[0]));
    DebugWrite(' (');
    DebugWrite(@Vendor[0]);
    DebugWriteLine(')');
  end
  else
    DebugWriteLine(@Vendor[0]);
  DebugEndMessage;
end;

end.
