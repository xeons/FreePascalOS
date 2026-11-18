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
  The USB HID class driver: takes HID interfaces (class 03h), one at a
  time, and hands their reports to a keyboard (Drivers.UsbKeyboard)
  and a pointer (Drivers.UsbPointer).

  Each HID interface has a report descriptor (GET_DESCRIPTOR 22h on the
  interface), parsed by Drivers.HidReports for a keyboard report and a
  pointer report. How the interface is driven (ChooseHidMode):

  - a boot keyboard interface (03/01/01) in the boot protocol: 8-byte
    reports straight to the keyboard. Unless its descriptor puts a
    pointer beside the keyboard by report id: then as below;
  - otherwise in the report protocol (asked for with SET_PROTOCOL on
    a boot interface: the firmware may have left it in the boot one):
    each report goes by its id to the keyboard (turned into the boot
    form), to the pointer, or nowhere (consumer and system control
    reports of a receiver);
  - a boot mouse (03/01/02) whose descriptor is of no use: the boot
    protocol's 3-byte reports.

  A wireless keyboard and mouse receiver usually has a boot keyboard
  interface and a mouse interface (a boot mouse, or reports with ids:
  the mouse, consumer control, system control); each is a HID interface
  of its own, each driven here, each with its interrupt IN endpoint.
}
unit Drivers.UsbHid;

{$mode objfpc}
{$pointermath on}

interface

{ Registers the class driver with the USB core (before the controllers
  start). }
procedure RegisterUsbHidDriver;

implementation

uses
  Runtime.Memory,
  Memory.KernelHeap,
  Drivers.Xhci,
  Drivers.UsbDescriptors,
  Drivers.UsbInterfaces,
  Drivers.HidReports,
  Drivers.UsbKeyboard,
  Drivers.UsbPointer,
  Debug.Output;

const
  RequestGetDescriptor = 6;
  RequestSetIdle = $0A;
  RequestSetProtocol = $0B;
  StandardFromInterface = $81;
  ClassRequestToInterface = $21;
  BootProtocol = 0;
  ReportProtocol = 1;
  MaximumReportDescriptor = 1024;

type
  PHidInterface = ^THidInterface;
  THidInterface = record
    Usb: PUsbDevice;
    InterfaceNumber: Byte;
    IsBootInterface: Boolean;
    Mode: THidInterfaceMode;
    Description: THidDescription;
    Keyboard: PUsbKeyboard;
    Pointer: PUsbPointer;
  end;

{ --- Reports ------------------------------------------------------------------ }

procedure HandleRoutedReport(Hid: PHidInterface; Data: PByte; Length: LongWord);
var
  Targets: THidReportTargets;
  Boot: TBootKeyboardReport;
begin
  Targets := HidReportTargets(Hid^.Description, Data, Length);
  if (HidTargetKeyboard in Targets) and (Hid^.Keyboard <> nil) and
     ReadKeyboardAsBoot(Hid^.Description.KeyboardLayout, Data, Length, Boot) then
    HandleUsbKeyboardReport(Hid^.Keyboard, Boot);
  if (HidTargetPointer in Targets) and (Hid^.Pointer <> nil) then
    HandleUsbPointerReport(Hid^.Pointer, Data, Length);
end;

procedure HandleReport(Device: PUsbDevice; Data: PByte; Length: LongWord; Context: Pointer);
var
  Hid: PHidInterface;
  Boot: TBootKeyboardReport;
begin
  Hid := PHidInterface(Context);
  case Hid^.Mode of
    HidModeBootKeyboard:
      if Length >= BootKeyboardReportSize then
      begin
        CopyMemory(@Boot[0], Data, BootKeyboardReportSize);
        HandleUsbKeyboardReport(Hid^.Keyboard, Boot);
      end;
    HidModeBootMouse:
      HandleUsbPointerReport(Hid^.Pointer, Data, Length);
    HidModeReports:
      HandleRoutedReport(Hid, Data, Length);
  end;
end;

{ --- Setting the interface up -------------------------------------------------- }

{ The protocol the mode needs (boot interfaces only have the choice),
  and reports only when something changes for a keyboard. }
procedure ChooseProtocol(Hid: PHidInterface);
var
  Protocol: Word;
begin
  if Hid^.IsBootInterface then
  begin
    Protocol := ReportProtocol;
    if Hid^.Mode in [HidModeBootKeyboard, HidModeBootMouse] then
      Protocol := BootProtocol;
    UsbControlTransfer(Hid^.Usb, ClassRequestToInterface, RequestSetProtocol, Protocol, Hid^.InterfaceNumber, nil, 0);
  end;
  if Hid^.Keyboard <> nil then
    UsbControlTransfer(Hid^.Usb, ClassRequestToInterface, RequestSetIdle, 0, Hid^.InterfaceNumber, nil, 0);
end;

{ After waking from suspend to RAM: the device forgot its protocol; keys
  and buttons count as released. }
procedure ResumeHidInterface(Usb: PUsbDevice; Context: Pointer);
var
  Hid: PHidInterface;
begin
  Hid := PHidInterface(Context);
  if Hid^.Keyboard <> nil then
    ResetUsbKeyboard(Hid^.Keyboard);
  if Hid^.Pointer <> nil then
    ResetUsbPointer(Hid^.Pointer);
  ChooseProtocol(Hid);
end;

{ The interface's report descriptor, parsed. }
function ReadReportDescriptor(Usb: PUsbDevice; UsbInterface: PUsbInterfaceInfo;
  out Description: THidDescription): Boolean;
var
  Length: Word;
  Descriptor: PByte;
begin
  ZeroMemory(@Description, SizeOf(Description));
  Length := UsbInterface^.HidReportLength;
  if (Length = 0) or (Length > MaximumReportDescriptor) then
    Exit(False);
  Descriptor := PByte(AllocateKernelMemory(Length));
  if Descriptor = nil then
    Exit(False);
  Result := UsbControlTransfer(Usb, StandardFromInterface, RequestGetDescriptor, Word(UsbDescriptorHidReport) shl 8,
    UsbInterface^.Number, Descriptor, Length) and ParseHidDescription(Descriptor, Length, Description);
  FreeKernelMemory(Descriptor);
end;

{ The keyboard and pointer the mode calls for; False if none could be
  had. }
function CreateConsumers(Hid: PHidInterface): Boolean;
var
  Layout: THidPointerLayout;
begin
  case Hid^.Mode of
    HidModeBootKeyboard:
      Hid^.Keyboard := CreateUsbKeyboard;
    HidModeBootMouse:
      begin
        BootMouseLayout(Layout);
        Hid^.Pointer := CreateUsbPointer(Layout);
      end;
    HidModeReports:
      begin
        if Hid^.Description.HasKeyboard then
          Hid^.Keyboard := CreateUsbKeyboard;
        if Hid^.Description.HasPointer then
          Hid^.Pointer := CreateUsbPointer(Hid^.Description.PointerLayout);
      end;
  end;
  Result := (Hid^.Keyboard <> nil) or (Hid^.Pointer <> nil);
end;

{ --- Log ------------------------------------------------------------------------ }

procedure WriteInterfaceStart(Usb: PUsbDevice; Number: Byte);
begin
  DebugWriteTag('usb');
  DebugWrite('Port ');
  DebugWriteDecimal(Usb^.PortNumber);
  DebugWrite(': interface ');
  DebugWriteDecimal(Number);
  DebugWrite(': ');
end;

procedure WriteReportUse(Name: PChar; Present: Boolean; Id: Byte; UsesIds: Boolean);
begin
  DebugWrite(Name);
  if not Present then
    DebugWrite(' none')
  else if UsesIds then
  begin
    DebugWrite(' report ');
    DebugWriteDecimal(Id);
  end
  else
    DebugWrite(' yes');
end;

{ How the interface is driven: the protocol, and with report ids which
  report goes where (the others are ignored). }
procedure WriteHidSummary(Hid: PHidInterface);
var
  Index: Integer;
begin
  DebugBeginMessage;
  WriteInterfaceStart(Hid^.Usb, Hid^.InterfaceNumber);
  case Hid^.Mode of
    HidModeBootKeyboard: DebugWriteLine('HID boot protocol keyboard');
    HidModeBootMouse: DebugWriteLine('HID boot protocol mouse (its report descriptor was of no use)');
  else
    begin
      DebugWrite('HID report protocol');
      if Hid^.Description.UsesReportIds then
      begin
        DebugWrite(', report ids');
        for Index := 0 to Hid^.Description.ReportCount - 1 do
        begin
          DebugWrite(' ');
          DebugWriteDecimal(Hid^.Description.ReportIds[Index]);
        end;
      end;
      DebugWrite(': ');
      WriteReportUse('keyboard', Hid^.Keyboard <> nil, Hid^.Description.KeyboardLayout.ReportId,
        Hid^.Description.UsesReportIds);
      DebugWrite(', ');
      WriteReportUse('pointer', Hid^.Pointer <> nil, Hid^.Description.PointerLayout.ReportId,
        Hid^.Description.UsesReportIds);
      DebugWriteLine('');
    end;
  end;
  DebugEndMessage;
end;

procedure WriteNotTaken(Usb: PUsbDevice; Number: Byte; Reason: PChar);
begin
  DebugBeginMessage;
  WriteInterfaceStart(Usb, Number);
  DebugWriteLine(Reason);
  DebugEndMessage;
end;

{ --- Taking an interface ---------------------------------------------------------- }

function ProbeUsbHid(Usb: PUsbDevice; UsbInterface: PUsbInterfaceInfo): Boolean;
var
  Hid: PHidInterface;
  Endpoint: TUsbEndpointInfo;
  Description: THidDescription;
  Parsed: Boolean;
  Mode: THidInterfaceMode;
begin
  Result := False;
  if (UsbInterface^.InterfaceClass <> UsbClassHid) or
     not FindUsbEndpoint(UsbInterface^, UsbTransferInterrupt, True, Endpoint) then
    Exit;
  Parsed := ReadReportDescriptor(Usb, UsbInterface, Description);
  Mode := ChooseHidMode(UsbInterface^.Subclass, UsbInterface^.Protocol, Parsed, Description);
  if Mode = HidModeNone then
  begin
    if Parsed then
      WriteNotTaken(Usb, UsbInterface^.Number, 'HID reports with no keyboard or pointer')
    else
      WriteNotTaken(Usb, UsbInterface^.Number, 'HID report descriptor not read or not understood');
    Exit;
  end;
  Hid := PHidInterface(AllocateZeroedKernelMemory(SizeOf(THidInterface)));
  if Hid = nil then
    Exit;
  Hid^.Usb := Usb;
  Hid^.InterfaceNumber := UsbInterface^.Number;
  Hid^.IsBootInterface := UsbInterface^.Subclass = UsbSubclassHidBoot;
  Hid^.Mode := Mode;
  Hid^.Description := Description;
  if not CreateConsumers(Hid) then
  begin
    WriteNotTaken(Usb, UsbInterface^.Number, 'HID left alone: too many keyboards or pointers');
    FreeKernelMemory(Hid);
    Exit;
  end;
  Result := True;
  ChooseProtocol(Hid);
  UsbAddResumeHandler(Usb, @ResumeHidInterface, Hid);
  WriteHidSummary(Hid);
  if not UsbStartInterruptIn(Usb, Endpoint.Address, Endpoint.MaximumPacket, Endpoint.Interval, @HandleReport, Hid) then
    WriteNotTaken(Usb, UsbInterface^.Number, 'its interrupt IN endpoint could not be started');
end;

procedure RegisterUsbHidDriver;
begin
  RegisterUsbClassDriver('hid', @ProbeUsbHid);
end;

end.
