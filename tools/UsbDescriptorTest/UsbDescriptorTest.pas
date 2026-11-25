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
  Host test of the USB configuration walking and HID report routing
  (make usb-descriptor-test: Drivers.UsbDescriptors, Drivers.HidReports).

  The descriptors are those of a typical wireless keyboard and mouse
  receiver, written from the HID specification's examples: interface 0
  a boot keyboard (the specification's keyboard descriptor, appendix B.1
  and E.6), interface 1 a boot mouse interface whose report descriptor
  has three reports by id: 1 the mouse (five buttons, 12-bit X and Y, a
  wheel), 2 consumer control (a 16-bit usage), 3 system control (power,
  sleep, wake). Also: the specification's boot mouse (no ids, appendix
  B.2), one interface carrying a keyboard (id 1) and a mouse (id 2), a
  keyboard reporting a bitmap of keys, an audio function with
  alternate settings, and a configuration cut short.

  Then what a broken or hostile device may send (UsbHostileDescriptorTests:
  endpoints 0, 80h and repeated addresses, report counts and sizes whose
  offsets wrap 32 bits, huge key arrays, descriptors cut short at every
  length), random mutations of the descriptors above
  (UsbDescriptorFuzzTests), all read from guarded buffers so a read past
  their end crashes the test, and the xHCI driver's ring and transfer
  bookkeeping (XhciBookkeepingTests).

  Prints every failed check and exits with 1 if there was one.
}
program UsbDescriptorTest;

{$mode objfpc}

uses
  SysUtils,
  Drivers.UsbDescriptors,
  Drivers.HidReports,
  UsbTestChecks,
  UsbHostileDescriptorTests,
  UsbDescriptorFuzzTests,
  XhciBookkeepingTests;

const
  { HID specification, appendix E.6: the boot keyboard (63 bytes). }
  KeyboardReportDescriptor: array[0..62] of Byte = (
    $05, $01, $09, $06, $A1, $01,                   { Generic Desktop, Keyboard, Application }
    $05, $07, $19, $E0, $29, $E7, $15, $00, $25, $01,
    $75, $01, $95, $08, $81, $02,                   { 8 modifier bits }
    $95, $01, $75, $08, $81, $01,                   { reserved byte }
    $95, $05, $75, $01, $05, $08, $19, $01, $29, $05, $91, $02, { 5 LEDs (output) }
    $95, $01, $75, $03, $91, $01,                   { LED padding }
    $95, $06, $75, $08, $15, $00, $25, $65, $05, $07, $19, $00, $29, $65, $81, $00, { 6 key array }
    $C0);

  { The receiver's mouse interface (118 bytes): report 1 the mouse,
    2 consumer control, 3 system control. }
  ReceiverMouseReportDescriptor: array[0..117] of Byte = (
    $05, $01, $09, $02, $A1, $01, $85, $01, $09, $01, $A1, $00, { Mouse, id 1, Pointer }
    $05, $09, $19, $01, $29, $05, $15, $00, $25, $01, $95, $05, $75, $01, $81, $02, { 5 buttons }
    $95, $01, $75, $03, $81, $01,                   { padding }
    $05, $01, $09, $30, $09, $31, $16, $01, $F8, $26, $FF, $07, $75, $0C, $95, $02, $81, $06, { X, Y: 12 bits, relative }
    $09, $38, $15, $81, $25, $7F, $75, $08, $95, $01, $81, $06, { wheel }
    $C0, $C0,
    $05, $0C, $09, $01, $A1, $01, $85, $02,          { Consumer Control, id 2 }
    $15, $00, $26, $FF, $03, $19, $00, $2A, $FF, $03, $75, $10, $95, $01, $81, $00,
    $C0,
    $05, $01, $09, $80, $A1, $01, $85, $03,          { System Control, id 3 }
    $19, $81, $29, $83, $15, $00, $25, $01, $75, $01, $95, $03, $81, $02, $95, $05, $81, $01,
    $C0);

  { HID specification, appendix E.10: the boot mouse (50 bytes, no
    ids), like QEMU's usb-mouse without the wheel. }
  BootMouseReportDescriptor: array[0..49] of Byte = (
    $05, $01, $09, $02, $A1, $01, $09, $01, $A1, $00,
    $05, $09, $19, $01, $29, $03, $15, $00, $25, $01, $95, $03, $75, $01, $81, $02,
    $95, $01, $75, $05, $81, $01,
    $05, $01, $09, $30, $09, $31, $15, $81, $25, $7F, $75, $08, $95, $02, $81, $06,
    $C0, $C0);

  { One interface, both devices: the keyboard as report 1, a boot style
    mouse as report 2. }
  CombinedReportDescriptor: array[0..116] of Byte = (
    $05, $01, $09, $06, $A1, $01, $85, $01,
    $05, $07, $19, $E0, $29, $E7, $15, $00, $25, $01, $75, $01, $95, $08, $81, $02,
    $95, $01, $75, $08, $81, $01,
    $95, $05, $75, $01, $05, $08, $19, $01, $29, $05, $91, $02,
    $95, $01, $75, $03, $91, $01,
    $95, $06, $75, $08, $15, $00, $25, $65, $05, $07, $19, $00, $29, $65, $81, $00,
    $C0,
    $05, $01, $09, $02, $A1, $01, $85, $02, $09, $01, $A1, $00,
    $05, $09, $19, $01, $29, $03, $15, $00, $25, $01, $95, $03, $75, $01, $81, $02,
    $95, $01, $75, $05, $81, $01,
    $05, $01, $09, $30, $09, $31, $15, $81, $25, $7F, $75, $08, $95, $02, $81, $06,
    $C0, $C0);

  { A keyboard reporting every key as a bit (usages 04h-63h, 96 bits)
    after the modifiers. }
  BitmapKeyboardReportDescriptor: array[0..30] of Byte = (
    $05, $01, $09, $06, $A1, $01,
    $05, $07, $19, $E0, $29, $E7, $15, $00, $25, $01, $75, $01, $95, $08, $81, $02,
    $19, $04, $29, $63, $95, $60, $81, $02,
    $C0);

  { The receiver's configuration descriptor: two HID interfaces. }
  ReceiverConfiguration: array[0..58] of Byte = (
    $09, $02, $3B, $00, $02, $01, $00, $A0, $32,     { configuration: 59 bytes, 2 interfaces }
    $09, $04, $00, $00, $01, $03, $01, $01, $00,     { interface 0: HID boot keyboard }
    $09, $21, $11, $01, $00, $01, $22, $3F, $00,     { HID 1.11, report descriptor 63 bytes }
    $07, $05, $81, $03, $08, $00, $0A,               { endpoint 81h interrupt IN, 8 bytes, 10 ms }
    $09, $04, $01, $00, $01, $03, $01, $02, $00,     { interface 1: HID boot mouse }
    $09, $21, $11, $01, $00, $01, $22, $76, $00,     { report descriptor 118 bytes }
    $07, $05, $82, $03, $08, $00, $01);              { endpoint 82h interrupt IN, 8 bytes, 1 ms }

  { An audio function: control interface, and a streaming interface whose
    setting 1 has the isochronous OUT endpoint; then a vendor interface. }
  AudioConfiguration: array[0..76] of Byte = (
    $09, $02, $4D, $00, $03, $01, $00, $80, $32,
    $09, $04, $00, $00, $00, $01, $01, $00, $00,     { interface 0: audio control }
    $09, $24, $01, $00, $01, $09, $00, $01, $01,     { class-specific header }
    $09, $04, $01, $00, $00, $01, $02, $00, $00,     { interface 1 setting 0: no endpoints }
    $09, $04, $01, $01, $01, $01, $02, $00, $00,     { interface 1 setting 1 }
    $07, $24, $01, $01, $01, $01, $00,               { class-specific general }
    $09, $05, $01, $09, $C0, $00, $01, $00, $00,     { endpoint 01h isochronous OUT, 192 bytes }
    $09, $04, $02, $00, $01, $FF, $00, $00, $00,     { interface 2: vendor specific }
    $07, $05, $83, $02, $40, $00, $00);              { endpoint 83h bulk IN, 64 bytes }

procedure CheckBoot(const Boot: TBootKeyboardReport; const Expected: array of Byte; const What: string);
var
  Index: Integer;
begin
  for Index := 0 to BootKeyboardReportSize - 1 do
    CheckNumber(Boot[Index], Expected[Index], What + ', byte ' + IntToStr(Index));
end;

{ --- Configuration descriptors ---------------------------------------------- }

procedure TestReceiverConfiguration;
var
  Configuration: TUsbConfigurationInfo;
  Keyboard: PUsbInterfaceInfo;
  Mouse: PUsbInterfaceInfo;
  Endpoint: TUsbEndpointInfo;
begin
  Check(ParseUsbConfiguration(@ReceiverConfiguration[0], Length(ReceiverConfiguration), Configuration),
    'the receiver''s configuration parses');
  CheckNumber(Configuration.InterfaceCount, 2, 'the receiver''s interface count');
  Keyboard := FindUsbInterface(Configuration, 0);
  Mouse := FindUsbInterface(Configuration, 1);
  Check((Keyboard <> nil) and (Mouse <> nil), 'interfaces 0 and 1 are found');
  Check(FindUsbInterface(Configuration, 2) = nil, 'there is no interface 2');
  if (Keyboard = nil) or (Mouse = nil) then
    Exit;
  CheckNumber(Keyboard^.InterfaceClass, UsbClassHid, 'interface 0''s class');
  CheckNumber(Keyboard^.Subclass, UsbSubclassHidBoot, 'interface 0''s subclass');
  CheckNumber(Keyboard^.Protocol, UsbProtocolHidKeyboard, 'interface 0''s protocol');
  CheckNumber(Keyboard^.HidReportLength, Length(KeyboardReportDescriptor), 'interface 0''s report descriptor length');
  CheckNumber(Keyboard^.EndpointCount, 1, 'interface 0''s endpoints');
  CheckNumber(Keyboard^.SettingCount, 1, 'interface 0''s settings');
  CheckNumber(Keyboard^.DescriptorOffset, 9, 'interface 0''s descriptors start');
  CheckNumber(Keyboard^.DescriptorLength, 25, 'interface 0''s descriptors length');
  Check(FindUsbEndpoint(Keyboard^, UsbTransferInterrupt, True, Endpoint), 'interface 0 has an interrupt IN endpoint');
  CheckNumber(Endpoint.Address, $81, 'interface 0''s endpoint');
  CheckNumber(Endpoint.MaximumPacket, 8, 'interface 0''s endpoint packet size');
  CheckNumber(Endpoint.Interval, 10, 'interface 0''s endpoint interval');
  Check(not FindUsbEndpoint(Keyboard^, UsbTransferInterrupt, False, Endpoint), 'interface 0 has no interrupt OUT');

  CheckNumber(Mouse^.Protocol, UsbProtocolHidMouse, 'interface 1''s protocol');
  CheckNumber(Mouse^.HidReportLength, Length(ReceiverMouseReportDescriptor), 'interface 1''s report descriptor length');
  Check(FindUsbEndpoint(Mouse^, UsbTransferInterrupt, True, Endpoint), 'interface 1 has an interrupt IN endpoint');
  CheckNumber(Endpoint.Address, $82, 'interface 1''s endpoint');
  CheckNumber(Mouse^.DescriptorOffset + Mouse^.DescriptorLength, Length(ReceiverConfiguration),
    'interface 1''s descriptors run to the end');

  Check(StrComp(UsbInterfaceKindName(3, 1, 1), 'HID boot keyboard') = 0, 'the boot keyboard''s name');
  Check(StrComp(UsbInterfaceKindName(3, 1, 2), 'HID boot mouse') = 0, 'the boot mouse''s name');
  Check(StrComp(UsbInterfaceKindName(3, 0, 0), 'HID') = 0, 'a report protocol HID interface''s name');
  Check(StrComp(UsbTransferTypeName($03), 'interrupt') = 0, 'the interrupt transfer''s name');
end;

procedure TestAudioConfiguration;
var
  Configuration: TUsbConfigurationInfo;
  Streaming: PUsbInterfaceInfo;
  Vendor: PUsbInterfaceInfo;
  Endpoint: TUsbEndpointInfo;
begin
  Check(ParseUsbConfiguration(@AudioConfiguration[0], Length(AudioConfiguration), Configuration),
    'the audio configuration parses');
  CheckNumber(Configuration.InterfaceCount, 3, 'the audio configuration''s interfaces (one per number)');
  Streaming := FindUsbInterface(Configuration, 1);
  Vendor := FindUsbInterface(Configuration, 2);
  if (Streaming = nil) or (Vendor = nil) then
  begin
    Check(False, 'the streaming and vendor interfaces are found');
    Exit;
  end;
  CheckNumber(Streaming^.SettingCount, 2, 'the streaming interface''s settings');
  CheckNumber(Streaming^.EndpointCount, 0, 'the streaming interface''s setting 0 endpoints');
  CheckNumber(Streaming^.Subclass, UsbSubclassAudioStreaming, 'the streaming interface''s subclass');
  CheckNumber(Streaming^.DescriptorOffset, 27, 'the streaming interface''s descriptors start');
  CheckNumber(Streaming^.DescriptorLength, 34, 'the streaming interface''s descriptors (both settings)');
  Check(StrComp(UsbInterfaceKindName(Streaming^.InterfaceClass, Streaming^.Subclass, Streaming^.Protocol),
    'audio streaming') = 0, 'the streaming interface''s name');
  Check(FindUsbEndpoint(Vendor^, UsbTransferBulk, True, Endpoint), 'the vendor interface''s bulk IN endpoint');
  CheckNumber(Endpoint.MaximumPacket, 64, 'the vendor endpoint''s packet size');
  Check(StrComp(UsbInterfaceKindName(Vendor^.InterfaceClass, 0, 0), 'vendor specific') = 0, 'the vendor interface''s name');
end;

procedure TestBrokenConfiguration;
var
  Configuration: TUsbConfigurationInfo;
  Broken: array[0..58] of Byte;
begin
  Broken := ReceiverConfiguration;
  { Interface 1's HID descriptor claims more bytes than there are. }
  Broken[43] := $40;
  Check(not ParseUsbConfiguration(@Broken[0], Length(Broken), Configuration), 'a cut short descriptor is noticed');
  CheckNumber(Configuration.InterfaceCount, 2, 'the interfaces up to it are kept');
  Check(not ParseUsbConfiguration(@KeyboardReportDescriptor[0], Length(KeyboardReportDescriptor), Configuration),
    'something not a configuration descriptor is refused');
end;

{ --- Report descriptors and reports ---------------------------------------- }

procedure TestReceiverMouse;
const
  { Left button, X +5, Y -3 (12 bits each), wheel +1. }
  MouseReport: array[0..5] of Byte = ($01, $01, $05, $D0, $FF, $01);
  { Volume up. }
  ConsumerReport: array[0..2] of Byte = ($02, $E9, $00);
  { Sleep. }
  SystemReport: array[0..1] of Byte = ($03, $02);
var
  Description: THidDescription;
  State: THidPointerState;
  Targets: THidReportTargets;
begin
  Check(ParseHidDescription(@ReceiverMouseReportDescriptor[0], Length(ReceiverMouseReportDescriptor), Description),
    'the receiver''s mouse descriptor parses');
  Check(Description.UsesReportIds, 'the receiver''s mouse descriptor uses report ids');
  Check(Description.HasPointer, 'it has a pointer');
  Check(not Description.HasKeyboard, 'it has no keyboard');
  CheckNumber(Description.ReportCount, 3, 'its reports');
  CheckNumber(Description.PointerLayout.ReportId, 1, 'the pointer''s report id');
  Check(Description.PointerLayout.X.Relative, 'X is relative');
  CheckNumber(Description.PointerLayout.X.BitOffset, 8, 'X''s bit offset');
  CheckNumber(Description.PointerLayout.X.BitSize, 12, 'X''s size');
  CheckNumber(Description.PointerLayout.Y.BitOffset, 20, 'Y''s bit offset');
  CheckNumber(Description.PointerLayout.Wheel.BitOffset, 32, 'the wheel''s bit offset');
  Check(Description.PointerLayout.Buttons[5].Present, 'button 5 is there');

  Targets := HidReportTargets(Description, @MouseReport[0], Length(MouseReport));
  Check(Targets = [HidTargetPointer], 'report 1 goes to the pointer');
  ReadPointerState(Description.PointerLayout, @MouseReport[0], Length(MouseReport), State);
  CheckNumber(State.X, 5, 'the mouse''s X');
  CheckNumber(State.Y, -3, 'the mouse''s Y');
  CheckNumber(State.Wheel, 1, 'the mouse''s wheel');
  CheckNumber(State.Buttons, 1 shl 1, 'the mouse''s buttons (left)');

  Targets := HidReportTargets(Description, @ConsumerReport[0], Length(ConsumerReport));
  Check(Targets = [], 'a consumer control report (2) goes nowhere');
  Targets := HidReportTargets(Description, @SystemReport[0], Length(SystemReport));
  Check(Targets = [], 'a system control report (3) goes nowhere');
  Check(HidReportTargets(Description, @MouseReport[0], 0) = [], 'an empty report goes nowhere');
end;

procedure TestBootKeyboard;
const
  { Left Shift and A, then B. }
  ShiftA: array[0..7] of Byte = ($02, $00, $04, $00, $00, $00, $00, $00);
var
  Description: THidDescription;
  Boot: TBootKeyboardReport;
begin
  Check(ParseHidDescription(@KeyboardReportDescriptor[0], Length(KeyboardReportDescriptor), Description),
    'the boot keyboard descriptor parses');
  Check(Description.HasKeyboard and not Description.HasPointer, 'the boot keyboard is a keyboard only');
  Check(not Description.UsesReportIds, 'the boot keyboard uses no report ids');
  CheckNumber(Description.KeyboardLayout.ReportBytes, 8, 'the boot keyboard''s report length');
  CheckNumber(Description.KeyboardLayout.KeyArrayCount, 6, 'the boot keyboard''s key slots');
  CheckNumber(Description.KeyboardLayout.KeyArray.BitOffset, 16, 'the key array''s bit offset');
  Check(HidReportTargets(Description, @ShiftA[0], Length(ShiftA)) = [HidTargetKeyboard],
    'a report without ids goes to the keyboard');
  Check(ReadKeyboardAsBoot(Description.KeyboardLayout, @ShiftA[0], Length(ShiftA), Boot), 'the report reads');
  CheckBoot(Boot, ShiftA, 'Shift and A as a boot report');
  Check(not ReadKeyboardAsBoot(Description.KeyboardLayout, @ShiftA[0], 5, Boot), 'a short report is refused');
end;

procedure TestCombinedInterface;
const
  { Report 1: Left Control, Right Shift, A and Z. }
  KeyboardReport: array[0..8] of Byte = ($01, $21, $00, $04, $1D, $00, $00, $00, $00);
  { Report 2: the middle button, X -2, Y +3. }
  MouseReport: array[0..3] of Byte = ($02, $04, $FE, $03);
var
  Description: THidDescription;
  Boot: TBootKeyboardReport;
  State: THidPointerState;
begin
  Check(ParseHidDescription(@CombinedReportDescriptor[0], Length(CombinedReportDescriptor), Description),
    'the combined descriptor parses');
  Check(Description.HasKeyboard and Description.HasPointer, 'it has a keyboard and a pointer');
  CheckNumber(Description.KeyboardLayout.ReportId, 1, 'the keyboard''s report id');
  CheckNumber(Description.PointerLayout.ReportId, 2, 'the pointer''s report id');
  Check(HidReportTargets(Description, @KeyboardReport[0], Length(KeyboardReport)) = [HidTargetKeyboard],
    'report 1 goes to the keyboard');
  Check(HidReportTargets(Description, @MouseReport[0], Length(MouseReport)) = [HidTargetPointer],
    'report 2 goes to the pointer');
  Check(ReadKeyboardAsBoot(Description.KeyboardLayout, @KeyboardReport[0], Length(KeyboardReport), Boot),
    'the keyboard report reads');
  CheckBoot(Boot, [$21, $00, $04, $1D, $00, $00, $00, $00], 'the keyboard report as a boot report');
  ReadPointerState(Description.PointerLayout, @MouseReport[0], Length(MouseReport), State);
  CheckNumber(State.X, -2, 'the combined mouse''s X');
  CheckNumber(State.Y, 3, 'the combined mouse''s Y');
  CheckNumber(State.Buttons, 1 shl 3, 'the combined mouse''s buttons (middle)');
end;

procedure TestBitmapKeyboard;
const
  { Left Alt; B (05h) and C (06h); Enter (28h). }
  Report: array[0..12] of Byte = ($04, $06, $00, $00, $00, $10, $00, $00, $00, $00, $00, $00, $00);
var
  Description: THidDescription;
  Boot: TBootKeyboardReport;
begin
  Check(ParseHidDescription(@BitmapKeyboardReportDescriptor[0], Length(BitmapKeyboardReportDescriptor), Description),
    'the bitmap keyboard descriptor parses');
  Check(Description.HasKeyboard, 'the bitmap keyboard is a keyboard');
  CheckNumber(Description.KeyboardLayout.KeyBitmapCount, 96, 'the bitmap''s keys');
  CheckNumber(Description.KeyboardLayout.KeyBitmapUsageMinimum, 4, 'the bitmap''s first key');
  Check(ReadKeyboardAsBoot(Description.KeyboardLayout, @Report[0], Length(Report), Boot), 'the bitmap report reads');
  CheckBoot(Boot, [$04, $00, $05, $06, $28, $00, $00, $00], 'the bitmap report as a boot report');
end;

procedure TestBootMouse;
const
  Report: array[0..2] of Byte = ($02, $10, $F0);
var
  Description: THidDescription;
  Layout: THidPointerLayout;
  State: THidPointerState;
begin
  Check(ParseHidDescription(@BootMouseReportDescriptor[0], Length(BootMouseReportDescriptor), Description),
    'the boot mouse descriptor parses');
  Check(Description.HasPointer and not Description.UsesReportIds, 'the boot mouse is a pointer without ids');
  Check(HidReportTargets(Description, @Report[0], Length(Report)) = [HidTargetPointer],
    'its reports go to the pointer');
  ReadPointerState(Description.PointerLayout, @Report[0], Length(Report), State);
  CheckNumber(State.X, 16, 'the boot mouse''s X');
  CheckNumber(State.Y, -16, 'the boot mouse''s Y');
  CheckNumber(State.Buttons, 1 shl 2, 'the boot mouse''s buttons (right)');
  { The fixed boot layout reads the same. }
  BootMouseLayout(Layout);
  ReadPointerState(Layout, @Report[0], Length(Report), State);
  CheckNumber(State.X, 16, 'the boot layout''s X');
  CheckNumber(State.Y, -16, 'the boot layout''s Y');
  CheckNumber(State.Buttons, 1 shl 2, 'the boot layout''s buttons');
end;

{ The lock lights' output reports: the boot keyboard's (no ids), the
  combined interface's (report 1), and the boot protocol's own. }
procedure TestKeyboardLights;
var
  Description: THidDescription;
  Layout: THidLightsLayout;
  Report: array[0..7] of Byte;
  Length: LongWord;
begin
  ParseHidDescription(@KeyboardReportDescriptor[0], System.Length(KeyboardReportDescriptor), Description);
  Check(Description.HasLights, 'the boot keyboard has lights');
  CheckNumber(Description.LightsLayout.ReportBytes, 1, 'its lights report length');
  CheckNumber(Description.LightsLayout.CapsLock.BitOffset, 1, 'its Caps Lock bit');
  Length := BuildLightsReport(Description.LightsLayout, HidLightCapsLock or HidLightScrollLock, @Report[0],
    SizeOf(Report));
  CheckNumber(Length, 1, 'the lights report''s length');
  CheckNumber(Report[0], $06, 'Caps Lock and Scroll Lock as bits');
  ParseHidDescription(@CombinedReportDescriptor[0], System.Length(CombinedReportDescriptor), Description);
  Check(Description.HasLights and Description.LightsLayout.UsesReportIds, 'the combined keyboard has lights by id');
  CheckNumber(Description.LightsLayout.ReportId, 1, 'its lights report id');
  Length := BuildLightsReport(Description.LightsLayout, HidLightNumLock, @Report[0], SizeOf(Report));
  CheckNumber(Length, 2, 'the id and the lights byte');
  Check((Report[0] = 1) and (Report[1] = $01), 'report 1 with Num Lock');
  CheckNumber(BuildLightsReport(Description.LightsLayout, HidLightNumLock, @Report[0], 1), 0,
    'a buffer too small for the report');
  ParseHidDescription(@BitmapKeyboardReportDescriptor[0], System.Length(BitmapKeyboardReportDescriptor), Description);
  Check(not Description.HasLights, 'the bitmap keyboard has no lights');
  BootLightsLayout(Layout);
  Length := BuildLightsReport(Layout, HidLightNumLock or HidLightCapsLock or HidLightScrollLock, @Report[0],
    SizeOf(Report));
  Check((Length = 1) and (Report[0] = $07), 'the boot protocol''s lights byte');
end;

procedure TestModes;
var
  Keyboard: THidDescription;
  ReceiverMouse: THidDescription;
  Combined: THidDescription;
  Nothing: THidDescription;
begin
  ParseHidDescription(@KeyboardReportDescriptor[0], Length(KeyboardReportDescriptor), Keyboard);
  ParseHidDescription(@ReceiverMouseReportDescriptor[0], Length(ReceiverMouseReportDescriptor), ReceiverMouse);
  ParseHidDescription(@CombinedReportDescriptor[0], Length(CombinedReportDescriptor), Combined);
  FillChar(Nothing, SizeOf(Nothing), 0);
  Check(ChooseHidMode(1, 1, True, Keyboard) = HidModeBootKeyboard, 'the receiver''s keyboard: boot protocol');
  Check(ChooseHidMode(1, 1, False, Nothing) = HidModeBootKeyboard, 'a boot keyboard without a descriptor: boot protocol');
  Check(ChooseHidMode(1, 2, True, ReceiverMouse) = HidModeReports, 'the receiver''s mouse: report protocol');
  Check(ChooseHidMode(1, 2, False, Nothing) = HidModeBootMouse, 'a boot mouse without a descriptor: boot protocol');
  Check(ChooseHidMode(1, 1, True, Combined) = HidModeReports, 'a boot keyboard with a mouse beside it: reports');
  Check(ChooseHidMode(0, 0, True, Combined) = HidModeReports, 'a combined report protocol interface: reports');
  Check(ChooseHidMode(0, 0, False, Nothing) = HidModeNone, 'a HID interface with nothing usable: none');
end;

begin
  TestReceiverConfiguration;
  TestAudioConfiguration;
  TestBrokenConfiguration;
  TestReceiverMouse;
  TestBootKeyboard;
  TestCombinedInterface;
  TestBitmapKeyboard;
  TestBootMouse;
  TestKeyboardLights;
  TestModes;
  TestHostileConfigurations;
  TestHostileReportDescriptors;
  FuzzConfiguration(@ReceiverConfiguration[0], Length(ReceiverConfiguration));
  FuzzConfiguration(@AudioConfiguration[0], Length(AudioConfiguration));
  FuzzReportDescriptor(@KeyboardReportDescriptor[0], Length(KeyboardReportDescriptor));
  FuzzReportDescriptor(@ReceiverMouseReportDescriptor[0], Length(ReceiverMouseReportDescriptor));
  FuzzReportDescriptor(@CombinedReportDescriptor[0], Length(CombinedReportDescriptor));
  FuzzReportDescriptor(@BitmapKeyboardReportDescriptor[0], Length(BitmapKeyboardReportDescriptor));
  FuzzReportDescriptor(@BootMouseReportDescriptor[0], Length(BootMouseReportDescriptor));
  TestXhciBookkeeping;
  if Failures > 0 then
  begin
    WriteLn('USB DESCRIPTOR TEST FAILED: ', Failures, ' checks');
    Halt(1);
  end;
  WriteLn('USB DESCRIPTOR TEST PASSED');
end.
