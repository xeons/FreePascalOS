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
  Binding class drivers to a USB device's interfaces.

  Once a device is configured, its configuration descriptor is walked
  (Drivers.UsbDescriptors) and each interface is offered to the class
  drivers in the order they registered, until one takes it. A driver
  takes an interface, not the device: a wireless keyboard and mouse
  receiver's boot keyboard interface and its mouse interface each get a
  driver (the HID driver twice), a disk's storage interface its own. A
  driver may claim further interfaces that belong to the function it
  drives (UsbClaimInterface: an audio function's streaming interface
  with its control interface); those are not offered again.

  Then each interface is logged, one line apiece, with what it is, its
  endpoints and the driver that took it ("no driver" otherwise):

    [usb] Port 2: interface 1 class 03/01/02 (HID boot mouse), endpoint 82 interrupt IN 8 bytes, driver hid
}
unit Drivers.UsbInterfaces;

{$mode objfpc}

interface

uses
  Drivers.UsbDescriptors,
  Drivers.Xhci;

type
  { Offered an interface of Device; True if the driver took it. }
  TUsbClassProbe = function(Device: PUsbDevice; UsbInterface: PUsbInterfaceInfo): Boolean;

{ Registers a class driver (before the controllers start). Name goes in
  the log. }
procedure RegisterUsbClassDriver(Name: PChar; Probe: TUsbClassProbe);
{ Called from a probe: claims interface Number of the device for the
  driver being offered one. False if there is no such interface or
  another driver has it. }
function UsbClaimInterface(Device: PUsbDevice; Number: Byte): Boolean;
{ Offers every interface of a configured device to the class drivers and
  logs what took each (the host controller driver calls it). }
procedure BindUsbInterfaces(Device: PUsbDevice);

implementation

uses
  Debug.Output;

const
  MaximumClassDrivers = 8;

type
  TClassDriver = record
    Name: PChar;
    Probe: TUsbClassProbe;
  end;

var
  ClassDrivers: array[0..MaximumClassDrivers - 1] of TClassDriver;
  ClassDriverCount: Integer;

procedure RegisterUsbClassDriver(Name: PChar; Probe: TUsbClassProbe);
begin
  if ClassDriverCount = MaximumClassDrivers then
    Exit;
  ClassDrivers[ClassDriverCount].Name := Name;
  ClassDrivers[ClassDriverCount].Probe := Probe;
  Inc(ClassDriverCount);
end;

function InterfaceIndexOf(Device: PUsbDevice; Number: Byte): Integer;
var
  Index: Integer;
begin
  for Index := 0 to Device^.Interfaces.InterfaceCount - 1 do
    if Device^.Interfaces.Interfaces[Index].Number = Number then
      Exit(Index);
  Result := -1;
end;

function UsbClaimInterface(Device: PUsbDevice; Number: Byte): Boolean;
var
  Index: Integer;
begin
  Index := InterfaceIndexOf(Device, Number);
  if (Index < 0) or (Device^.ProbingDriver = nil) or
     ((Device^.InterfaceDrivers[Index] <> nil) and (Device^.InterfaceDrivers[Index] <> Device^.ProbingDriver)) then
    Exit(False);
  Device^.InterfaceDrivers[Index] := Device^.ProbingDriver;
  Result := True;
end;

{ Offers one interface to each driver in turn until one takes it. }
procedure OfferInterface(Device: PUsbDevice; Index: Integer);
var
  DriverIndex: Integer;
begin
  for DriverIndex := 0 to ClassDriverCount - 1 do
  begin
    Device^.ProbingDriver := ClassDrivers[DriverIndex].Name;
    if ClassDrivers[DriverIndex].Probe(Device, @Device^.Interfaces.Interfaces[Index]) then
    begin
      Device^.InterfaceDrivers[Index] := ClassDrivers[DriverIndex].Name;
      Break;
    end;
  end;
  Device^.ProbingDriver := nil;
end;

procedure WriteEndpoint(const Endpoint: TUsbEndpointInfo);
begin
  DebugWriteHex(Endpoint.Address, 2);
  DebugWrite(' ');
  DebugWrite(UsbTransferTypeName(Endpoint.Attributes));
  if (Endpoint.Address and $80) <> 0 then
    DebugWrite(' IN ')
  else
    DebugWrite(' OUT ');
  DebugWriteDecimal(Endpoint.MaximumPacket);
  DebugWrite(' bytes');
end;

procedure WriteInterfaceLine(Device: PUsbDevice; Index: Integer);
var
  UsbInterface: PUsbInterfaceInfo;
  Endpoint: Integer;
begin
  UsbInterface := @Device^.Interfaces.Interfaces[Index];
  DebugBeginMessage;
  DebugWriteTag('usb');
  DebugWrite('Port ');
  DebugWriteDecimal(Device^.PortNumber);
  DebugWrite(': interface ');
  DebugWriteDecimal(UsbInterface^.Number);
  DebugWrite(' class ');
  DebugWriteHex(UsbInterface^.InterfaceClass, 2);
  DebugWrite('/');
  DebugWriteHex(UsbInterface^.Subclass, 2);
  DebugWrite('/');
  DebugWriteHex(UsbInterface^.Protocol, 2);
  DebugWrite(' (');
  DebugWrite(UsbInterfaceKindName(UsbInterface^.InterfaceClass, UsbInterface^.Subclass, UsbInterface^.Protocol));
  DebugWrite(')');
  if UsbInterface^.SettingCount > 1 then
  begin
    DebugWrite(', ');
    DebugWriteDecimal(UsbInterface^.SettingCount);
    DebugWrite(' settings');
  end;
  if UsbInterface^.EndpointCount = 0 then
    DebugWrite(', no endpoints')
  else if UsbInterface^.EndpointCount = 1 then
    DebugWrite(', endpoint ')
  else
    DebugWrite(', endpoints ');
  for Endpoint := 0 to UsbInterface^.EndpointCount - 1 do
  begin
    if Endpoint > 0 then
      DebugWrite(' + ');
    WriteEndpoint(UsbInterface^.Endpoints[Endpoint]);
  end;
  if UsbInterface^.HidReportLength <> 0 then
  begin
    DebugWrite(', report descriptor ');
    DebugWriteDecimal(UsbInterface^.HidReportLength);
    DebugWrite(' bytes');
  end;
  if Device^.InterfaceDrivers[Index] <> nil then
  begin
    DebugWrite(', driver ');
    DebugWriteLine(Device^.InterfaceDrivers[Index]);
  end
  else
    DebugWriteLine(', no driver');
  DebugEndMessage;
end;

procedure WriteBadConfiguration(Device: PUsbDevice);
begin
  DebugBeginMessage;
  DebugWriteTag('usb');
  DebugWrite('Port ');
  DebugWriteDecimal(Device^.PortNumber);
  DebugWriteLine(': its configuration descriptor is cut short; the interfaces before that are used');
  DebugEndMessage;
end;

procedure BindUsbInterfaces(Device: PUsbDevice);
var
  Index: Integer;
begin
  if not ParseUsbConfiguration(Device^.Configuration, Device^.ConfigurationLength, Device^.Interfaces) then
    WriteBadConfiguration(Device);
  for Index := 0 to Device^.Interfaces.InterfaceCount - 1 do
    if Device^.InterfaceDrivers[Index] = nil then
      OfferInterface(Device, Index);
  { After every offer: a driver may claim an interface after it, or one
    already passed over. }
  for Index := 0 to Device^.Interfaces.InterfaceCount - 1 do
    WriteInterfaceLine(Device, Index);
end;

end.
