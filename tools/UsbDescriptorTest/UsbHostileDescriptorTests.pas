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
  Descriptors a broken or hostile USB device may send, crafted to hit
  what used to go wrong: endpoint descriptors naming endpoint 0 (00h,
  80h, which the xHCI driver turned into device context 0 and the
  control endpoint's own ring), repeated addresses and reserved bits;
  report descriptors whose report count times size wraps 32 bits (so a
  key bitmap was read about 512 MiB past the report), a key array of a
  thousand or four billion entries (read at dispatch level), and every
  descriptor cut short at every length. Everything is read from guarded
  buffers (UsbTestChecks.GuardedCopy).
}
unit UsbHostileDescriptorTests;

{$mode objfpc}
{$pointermath on}

interface

procedure TestHostileConfigurations;
procedure TestHostileReportDescriptors;

implementation

uses
  SysUtils,
  Drivers.UsbDescriptors,
  Drivers.HidReports,
  UsbTestChecks;

const
  { One HID interface whose endpoints are: 00h and 80h (endpoint 0),
    81h interrupt IN (kept), 81h again, 91h (a reserved bit), 02h of the
    control type, 03h bulk OUT with no packet size, 02h bulk OUT
    (kept). }
  HostileEndpointsConfiguration: array[0..73] of Byte = (
    $09, $02, 74, $00, $01, $01, $00, $80, $32,
    $09, $04, $00, $00, $08, $03, $00, $00, $00,
    $07, $05, $00, $03, $08, $00, $0A,
    $07, $05, $80, $03, $08, $00, $0A,
    $07, $05, $81, $03, $08, $00, $0A,
    $07, $05, $81, $02, $40, $00, $00,
    $07, $05, $91, $03, $08, $00, $0A,
    $07, $05, $02, $00, $40, $00, $00,
    $07, $05, $03, $02, $00, $00, $00,
    $07, $05, $02, $02, $40, $00, $00);

  { A keyboard's modifiers, then constant padding of 07FFFFF0h fields of
    32 bits (2^32 - 512 bits), a 96-key bitmap, and 512 more padding
    bits: the report's length wraps 32 bits to 13 bytes, with the bitmap
    left near bit 2^32. }
  WrappingBitmapDescriptor: array[0..49] of Byte = (
    $05, $01, $09, $06, $A1, $01,
    $05, $07, $19, $E0, $29, $E7, $15, $00, $25, $01, $75, $01, $95, $08, $81, $02,
    $75, $20, $97, $F0, $FF, $FF, $07, $81, $01,
    $75, $01, $19, $04, $29, $63, $96, $60, $00, $81, $02,
    $75, $20, $95, $10, $81, $01,
    $C0, $C0);

  { A key array of 1000 8-bit entries (8000 bits: a report of 1000
    bytes, still taken), and one of FFFFFFFFh. }
  LongKeyArrayDescriptor: array[0..23] of Byte = (
    $05, $01, $09, $06, $A1, $01,
    $05, $07, $19, $00, $29, $65, $15, $00, $25, $65, $75, $08, $96, $E8, $03, $81, $00,
    $C0);
  HugeKeyArrayDescriptor: array[0..24] of Byte = (
    $05, $01, $09, $06, $A1, $01,
    $05, $07, $19, $00, $29, $65, $15, $00, $25, $65, $75, $08, $97, $FF, $FF, $FF, $FF, $81,
    $00);

  { A pointer whose X field is 32 bits wide and then whose report count
    times 33-bit fields is 2^32 + 132 bits. }
  WideFieldDescriptor: array[0..29] of Byte = (
    $05, $01, $09, $02, $A1, $01,
    $09, $30, $09, $31, $75, $08, $95, $02, $81, $06,
    $75, $21, $97, $04, $00, $00, $80, $81, $01,
    $09, $38, $81, $06, $C0);

procedure CheckConfigurationInvariants(const Configuration: TUsbConfigurationInfo; Length: LongWord;
  const What: string);
var
  Index: Integer;
  Endpoint: Integer;
  Other: Integer;
  UsbInterface: ^TUsbInterfaceInfo;
begin
  Check((Configuration.InterfaceCount >= 0) and (Configuration.InterfaceCount <= MaximumUsbInterfaces),
    What + ': the interface count is in range');
  for Index := 0 to Configuration.InterfaceCount - 1 do
  begin
    UsbInterface := @Configuration.Interfaces[Index];
    Check(QWord(UsbInterface^.DescriptorOffset) + UsbInterface^.DescriptorLength <= Length,
      What + ': an interface''s descriptors lie inside the configuration');
    Check((UsbInterface^.EndpointCount >= 0) and (UsbInterface^.EndpointCount <= MaximumInterfaceEndpoints),
      What + ': the endpoint count is in range');
    for Endpoint := 0 to UsbInterface^.EndpointCount - 1 do
    begin
      Check(UsbEndpointAddressIsValid(UsbInterface^.Endpoints[Endpoint].Address),
        What + ': every endpoint kept has a valid address');
      Check((UsbInterface^.Endpoints[Endpoint].Attributes and 3) <> UsbTransferControl,
        What + ': no control endpoint is kept');
      Check(UsbInterface^.Endpoints[Endpoint].MaximumPacket <> 0, What + ': every endpoint kept has a packet size');
      for Other := 0 to Endpoint - 1 do
        Check(UsbInterface^.Endpoints[Other].Address <> UsbInterface^.Endpoints[Endpoint].Address,
          What + ': no address is kept twice');
    end;
  end;
end;

procedure TestHostileConfigurations;
var
  Configuration: TUsbConfigurationInfo;
  UsbInterface: PUsbInterfaceInfo;
  Length: LongWord;
  Guarded: PByte;
begin
  Check(not UsbEndpointAddressIsValid($00), 'endpoint 00h is not valid');
  Check(not UsbEndpointAddressIsValid($80), 'endpoint 80h is not valid');
  Check(not UsbEndpointAddressIsValid($91), 'an address with a reserved bit is not valid');
  Check(UsbEndpointAddressIsValid($8F) and UsbEndpointAddressIsValid($01), 'endpoints 8Fh and 01h are valid');

  Guarded := GuardedCopy(@HostileEndpointsConfiguration[0], SizeOf(HostileEndpointsConfiguration));
  Check(ParseUsbConfiguration(Guarded, SizeOf(HostileEndpointsConfiguration), Configuration),
    'the hostile endpoints configuration parses');
  UsbInterface := FindUsbInterface(Configuration, 0);
  Check(UsbInterface <> nil, 'its interface is there');
  if UsbInterface <> nil then
  begin
    CheckNumber(UsbInterface^.EndpointCount, 2, 'the endpoints kept of eight');
    CheckNumber(UsbInterface^.Endpoints[0].Address, $81, 'the first endpoint kept');
    CheckNumber(UsbInterface^.Endpoints[1].Address, $02, 'the second endpoint kept');
  end;
  CheckConfigurationInvariants(Configuration, SizeOf(HostileEndpointsConfiguration), 'the hostile endpoints');

  { Cut short at every length. }
  for Length := 0 to SizeOf(HostileEndpointsConfiguration) do
  begin
    Guarded := GuardedCopy(@HostileEndpointsConfiguration[0], Length);
    ParseUsbConfiguration(Guarded, Length, Configuration);
    CheckConfigurationInvariants(Configuration, Length, 'cut short at ' + IntToStr(Length));
  end;
end;

{ Every report the description takes is no longer than allowed, and
  every field lies inside it. }
procedure CheckFieldInside(const Field: THidField; const What: string);
begin
  if Field.Present then
    Check(QWord(Field.BitOffset) + Field.BitSize <= MaximumHidReportBits, What + ' lies inside the longest report');
end;

procedure CheckDescriptionInvariants(const Description: THidDescription; const What: string);
var
  Index: Integer;
begin
  if Description.HasPointer then
  begin
    CheckFieldInside(Description.PointerLayout.X, What + ': X');
    CheckFieldInside(Description.PointerLayout.Y, What + ': Y');
    CheckFieldInside(Description.PointerLayout.Wheel, What + ': the wheel');
    for Index := 1 to MaximumPointerButtons do
      CheckFieldInside(Description.PointerLayout.Buttons[Index], What + ': a button');
  end;
  if Description.HasKeyboard then
  begin
    Check(Description.KeyboardLayout.ReportBytes <= MaximumHidReportBytes, What + ': the keyboard report''s length');
    Check(Description.KeyboardLayout.KeyArrayCount <= MaximumKeyArrayEntries, What + ': the key array''s entries');
    Check(QWord(Description.KeyboardLayout.KeyBitmapOffset) + Description.KeyboardLayout.KeyBitmapCount <=
      MaximumHidReportBits, What + ': the key bitmap lies inside the longest report');
    for Index := 0 to 7 do
      CheckFieldInside(Description.KeyboardLayout.Modifiers[Index], What + ': a modifier');
  end;
end;

{ Reads reports of a few lengths (zeros, then ones) with every layout
  the description has, from guarded buffers. }
procedure ReadReports(const Description: THidDescription);
const
  Lengths: array[0..6] of LongWord = (0, 1, 3, 8, 13, 64, 1025);
var
  Index: Integer;
  Guarded: PByte;
  Boot: TBootKeyboardReport;
  State: THidPointerState;
  Fill: Byte;
begin
  for Fill := 0 to 1 do
    for Index := Low(Lengths) to High(Lengths) do
    begin
      Guarded := GuardedCopy(nil, Lengths[Index]);
      if Fill = 1 then
        FillChar(Guarded^, Lengths[Index], $FF);
      HidReportTargets(Description, Guarded, Lengths[Index]);
      if Description.HasKeyboard then
        ReadKeyboardAsBoot(Description.KeyboardLayout, Guarded, Lengths[Index], Boot);
      if Description.HasPointer then
        ReadPointerState(Description.PointerLayout, Guarded, Lengths[Index], State);
    end;
end;

procedure ParseGuarded(Data: PByte; Length: LongWord; out Description: THidDescription);
begin
  ParseHidDescription(GuardedCopy(Data, Length), Length, Description);
end;

procedure TestCutShort(Data: PByte; Length: LongWord; const Name: string);
var
  Cut: LongWord;
  Description: THidDescription;
begin
  for Cut := 0 to Length do
  begin
    ParseGuarded(Data, Cut, Description);
    CheckDescriptionInvariants(Description, Name + ' cut short at ' + IntToStr(Cut));
    ReadReports(Description);
  end;
end;

procedure TestHandMadeLayouts;
var
  Field: THidField;
  Layout: THidKeyboardLayout;
  Guarded: PByte;
  Boot: TBootKeyboardReport;
begin
  { A field just below 2^32 bits, behind a report id: the length check
    must not wrap. }
  FillChar(Field, SizeOf(Field), 0);
  Field.Present := True;
  Field.BitSize := 16;
  Field.BitOffset := $FFFFFFF8;
  Guarded := GuardedCopy(nil, 4);
  CheckNumber(ReadHidField(True, Field, Guarded, 4), 0, 'a field past the report reads as 0');
  { A key bitmap far past a short report. }
  FillChar(Layout, SizeOf(Layout), 0);
  Layout.ReportBytes := 1;
  Layout.KeyBitmapOffset := $FFFFFF00;
  Layout.KeyBitmapCount := 96;
  Layout.KeyBitmapUsageMinimum := 4;
  Guarded := GuardedCopy(nil, 8);
  FillChar(Guarded^, 8, $FF);
  Check(ReadKeyboardAsBoot(Layout, Guarded, 8, Boot), 'a report with a bitmap past it still reads');
  CheckNumber(Boot[2], 0, 'no key comes from past the report');
  { A key array that would run past the report. }
  FillChar(Layout, SizeOf(Layout), 0);
  Layout.KeyArray.Present := True;
  Layout.KeyArray.BitSize := 8;
  Layout.KeyArray.LogicalMaximum := $65;
  Layout.KeyArrayCount := $FFFFFFFF;
  Layout.KeyArrayUsageMinimum := 0;
  Guarded := GuardedCopy(nil, 8);
  Check(ReadKeyboardAsBoot(Layout, Guarded, 8, Boot), 'a report with a huge key array reads');
end;

procedure TestHostileReportDescriptors;
var
  Description: THidDescription;
begin
  ParseGuarded(@WrappingBitmapDescriptor[0], SizeOf(WrappingBitmapDescriptor), Description);
  Check(not Description.HasKeyboard, 'a report whose length wraps 32 bits is not used');
  CheckDescriptionInvariants(Description, 'the wrapping bitmap');
  ReadReports(Description);

  ParseGuarded(@LongKeyArrayDescriptor[0], SizeOf(LongKeyArrayDescriptor), Description);
  Check(Description.HasKeyboard, 'a 1000-key array keyboard is taken');
  CheckNumber(Description.KeyboardLayout.KeyArrayCount, MaximumKeyArrayEntries, 'its key array is cut short');
  CheckNumber(Description.KeyboardLayout.ReportBytes, 1000, 'its report''s length');
  CheckDescriptionInvariants(Description, 'the long key array');
  ReadReports(Description);

  ParseGuarded(@HugeKeyArrayDescriptor[0], SizeOf(HugeKeyArrayDescriptor), Description);
  Check(not Description.HasKeyboard, 'a key array of FFFFFFFFh entries is not used');
  CheckDescriptionInvariants(Description, 'the huge key array');

  ParseGuarded(@WideFieldDescriptor[0], SizeOf(WideFieldDescriptor), Description);
  Check(not Description.HasPointer, 'a pointer report whose length wraps 32 bits is not used');
  CheckDescriptionInvariants(Description, 'the wide fields');
  ReadReports(Description);

  TestCutShort(@WrappingBitmapDescriptor[0], SizeOf(WrappingBitmapDescriptor), 'the wrapping bitmap');
  TestCutShort(@LongKeyArrayDescriptor[0], SizeOf(LongKeyArrayDescriptor), 'the long key array');
  TestCutShort(@WideFieldDescriptor[0], SizeOf(WideFieldDescriptor), 'the wide fields');
  TestHandMadeLayouts;
end;

end.
