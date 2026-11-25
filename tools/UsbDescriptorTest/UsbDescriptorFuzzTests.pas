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
  Random mutations of real descriptors: bytes changed (to random values
  and to the extremes 00h, 7Fh, 80h, FFh), inserted, removed, and the
  descriptor cut short, a few at a time, many thousands of times (from
  a fixed seed, so a failure repeats). Each mutant is parsed and its
  reports read from guarded buffers, and what the parsers return must
  hold together: every field inside the longest report, no endpoint 0,
  no repeated endpoint, every interface's descriptors inside the
  configuration.
}
unit UsbDescriptorFuzzTests;

{$mode objfpc}
{$pointermath on}

interface

procedure FuzzConfiguration(Data: PByte; Length: LongWord);
procedure FuzzReportDescriptor(Data: PByte; Length: LongWord);

implementation

uses
  SysUtils,
  Drivers.UsbDescriptors,
  Drivers.HidReports,
  UsbTestChecks;

const
  Rounds = 20000;
  MaximumMutantLength = 1024;
  MaximumMutationsPerRound = 6;

type
  TMutant = record
    Bytes: array[0..MaximumMutantLength - 1] of Byte;
    Length: LongWord;
  end;

var
  RandomState: QWord = QWord($1E3779B97F4A7C15);

{ xorshift64: the same numbers on every run. }
function NextRandom(Bound: LongWord): LongWord;
begin
  RandomState := RandomState xor (RandomState shl 13);
  RandomState := RandomState xor (RandomState shr 7);
  RandomState := RandomState xor (RandomState shl 17);
  if Bound = 0 then
    Exit(0);
  Result := LongWord(RandomState mod Bound);
end;

function InterestingByte: Byte;
const
  Values: array[0..7] of Byte = ($00, $01, $7F, $80, $FE, $FF, $20, $40);
begin
  if NextRandom(2) = 0 then
    Result := Values[NextRandom(Length(Values))]
  else
    Result := Byte(NextRandom(256));
end;

procedure Mutate(var Mutant: TMutant);
var
  Position: LongWord;
begin
  case NextRandom(5) of
    0, 1:
      if Mutant.Length > 0 then
        Mutant.Bytes[NextRandom(Mutant.Length)] := InterestingByte;
    2:
      if Mutant.Length < MaximumMutantLength then
      begin
        Position := NextRandom(Mutant.Length + 1);
        Move(Mutant.Bytes[Position], Mutant.Bytes[Position + 1], Mutant.Length - Position);
        Mutant.Bytes[Position] := InterestingByte;
        Inc(Mutant.Length);
      end;
    3:
      if Mutant.Length > 0 then
      begin
        Position := NextRandom(Mutant.Length);
        Move(Mutant.Bytes[Position + 1], Mutant.Bytes[Position], Mutant.Length - Position - 1);
        Dec(Mutant.Length);
      end;
    4:
      Mutant.Length := NextRandom(Mutant.Length + 1);
  end;
end;

procedure MakeMutant(Data: PByte; Length: LongWord; out Mutant: TMutant);
var
  Count: LongWord;
  Index: LongWord;
begin
  if Length > MaximumMutantLength then
    Length := MaximumMutantLength;
  Move(Data^, Mutant.Bytes[0], Length);
  Mutant.Length := Length;
  Count := 1 + NextRandom(MaximumMutationsPerRound);
  for Index := 1 to Count do
    Mutate(Mutant);
end;

function ConfigurationHoldsTogether(const Configuration: TUsbConfigurationInfo; Length: LongWord): Boolean;
var
  Index: Integer;
  Endpoint: Integer;
  Other: Integer;
  UsbInterface: ^TUsbInterfaceInfo;
begin
  Result := False;
  if (Configuration.InterfaceCount < 0) or (Configuration.InterfaceCount > MaximumUsbInterfaces) then
    Exit;
  for Index := 0 to Configuration.InterfaceCount - 1 do
  begin
    UsbInterface := @Configuration.Interfaces[Index];
    if QWord(UsbInterface^.DescriptorOffset) + UsbInterface^.DescriptorLength > Length then
      Exit;
    if (UsbInterface^.EndpointCount < 0) or (UsbInterface^.EndpointCount > MaximumInterfaceEndpoints) then
      Exit;
    for Endpoint := 0 to UsbInterface^.EndpointCount - 1 do
    begin
      if not UsbEndpointAddressIsValid(UsbInterface^.Endpoints[Endpoint].Address) or
         ((UsbInterface^.Endpoints[Endpoint].Attributes and 3) = UsbTransferControl) or
         (UsbInterface^.Endpoints[Endpoint].MaximumPacket = 0) then
        Exit;
      for Other := 0 to Endpoint - 1 do
        if UsbInterface^.Endpoints[Other].Address = UsbInterface^.Endpoints[Endpoint].Address then
          Exit;
    end;
  end;
  Result := True;
end;

procedure FuzzConfiguration(Data: PByte; Length: LongWord);
var
  Round: Integer;
  Mutant: TMutant;
  Configuration: TUsbConfigurationInfo;
  Broken: Integer;
begin
  Broken := 0;
  for Round := 1 to Rounds do
  begin
    MakeMutant(Data, Length, Mutant);
    ParseUsbConfiguration(GuardedCopy(@Mutant.Bytes[0], Mutant.Length), Mutant.Length, Configuration);
    if not ConfigurationHoldsTogether(Configuration, Mutant.Length) then
      Inc(Broken);
  end;
  CheckNumber(Broken, 0, 'mutated configurations that did not hold together');
end;

function FieldInside(const Field: THidField): Boolean;
begin
  Result := not Field.Present or (QWord(Field.BitOffset) + Field.BitSize <= MaximumHidReportBits);
end;

function DescriptionHoldsTogether(const Description: THidDescription): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if (Description.ReportCount < 0) or (Description.ReportCount > MaximumHidReports) then
    Exit;
  if Description.HasPointer then
  begin
    if not FieldInside(Description.PointerLayout.X) or not FieldInside(Description.PointerLayout.Y) or
       not FieldInside(Description.PointerLayout.Wheel) then
      Exit;
    for Index := 1 to MaximumPointerButtons do
      if not FieldInside(Description.PointerLayout.Buttons[Index]) then
        Exit;
  end;
  if Description.HasKeyboard then
  begin
    if (Description.KeyboardLayout.ReportBytes > MaximumHidReportBytes) or
       (Description.KeyboardLayout.KeyArrayCount > MaximumKeyArrayEntries) or
       (QWord(Description.KeyboardLayout.KeyBitmapOffset) + Description.KeyboardLayout.KeyBitmapCount >
        MaximumHidReportBits) or not FieldInside(Description.KeyboardLayout.KeyArray) then
      Exit;
    for Index := 0 to 7 do
      if not FieldInside(Description.KeyboardLayout.Modifiers[Index]) then
        Exit;
  end;
  Result := True;
end;

{ A report of random length and bytes, read with every layout. }
procedure ReadRandomReport(const Description: THidDescription);
var
  Length: LongWord;
  Report: PByte;
  Index: LongWord;
  Boot: TBootKeyboardReport;
  State: THidPointerState;
begin
  Length := NextRandom(80);
  if NextRandom(8) = 0 then
    Length := NextRandom(MaximumHidReportBytes + 2);
  Report := GuardedCopy(nil, Length);
  Index := 0;
  while Index < Length do
  begin
    Report[Index] := Byte(NextRandom(256));
    Inc(Index);
  end;
  HidReportTargets(Description, Report, Length);
  if Description.HasKeyboard then
    ReadKeyboardAsBoot(Description.KeyboardLayout, Report, Length, Boot);
  if Description.HasPointer then
    ReadPointerState(Description.PointerLayout, Report, Length, State);
end;

procedure FuzzReportDescriptor(Data: PByte; Length: LongWord);
var
  Round: Integer;
  Mutant: TMutant;
  Description: THidDescription;
  Broken: Integer;
begin
  Broken := 0;
  for Round := 1 to Rounds do
  begin
    MakeMutant(Data, Length, Mutant);
    ParseHidDescription(GuardedCopy(@Mutant.Bytes[0], Mutant.Length), Mutant.Length, Description);
    if not DescriptionHoldsTogether(Description) then
      Inc(Broken);
    ReadRandomReport(Description);
  end;
  CheckNumber(Broken, 0, 'mutated report descriptors that did not hold together');
end;

end.
