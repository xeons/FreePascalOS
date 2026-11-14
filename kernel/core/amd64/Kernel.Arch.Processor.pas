{
  Boot processor setup for x86-64: descriptor tables, interrupt table and
  processor identification.
}
unit Kernel.Arch.Processor;

{$mode objfpc}

interface

procedure InitializeBootProcessor;
procedure WriteProcessorDescription;

implementation

uses
  Runtime.Text,
  Kernel.Arch.Cpu,
  Kernel.Arch.DescriptorTables,
  Kernel.Arch.InterruptTable,
  Debug.Output;

const
  CpuidVendor = 0;
  CpuidBrandStringFirst = $80000002;
  CpuidBrandStringLast = $80000004;
  CpuidHighestExtendedLeaf = $80000000;

  BrandStringLength = 48;

procedure InitializeBootProcessor;
begin
  InitializeDescriptorTables;
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
