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
  A USB configuration descriptor as the list of its interfaces: what the
  USB core offers the class drivers, one interface at a time.

  The configuration descriptor (read whole at enumeration) is a chain of
  descriptors, each starting with its length and type: the
  configuration's own, then for each interface its interface
  descriptor, class-specific descriptors (a HID descriptor, say) and its
  endpoints. An interface may come several times, once per alternate
  setting; the list has one entry per interface number, with the class
  and endpoints of setting 0 (the one in force after SET_CONFIGURATION)
  and where all its settings' descriptors are, for drivers that look
  further (audio streaming settings).

  The descriptors come from the device, which may be broken or hostile:
  an endpoint descriptor naming endpoint 0 (the default control
  endpoint, which only the USB core uses), setting reserved address
  bits, of the control type, with no packet size, or repeating an
  address already listed for its interface is left out, so no class
  driver is ever handed an endpoint that would take the place of
  another one.

  Plain Pascal with no kernel dependencies: the host test
  (tools/UsbDescriptorTest) walks real descriptors with it.
}
unit Drivers.UsbDescriptors;

{$mode objfpc}
{$pointermath on}

interface

const
  MaximumUsbInterfaces = 16;
  MaximumInterfaceEndpoints = 8;

  UsbDescriptorDevice = 1;
  UsbDescriptorConfiguration = 2;
  UsbDescriptorInterface = 4;
  UsbDescriptorEndpoint = 5;
  UsbDescriptorHid = $21;
  UsbDescriptorHidReport = $22;

  UsbTransferControl = 0;
  UsbTransferIsochronous = 1;
  UsbTransferBulk = 2;
  UsbTransferInterrupt = 3;

  UsbClassAudio = $01;
  UsbClassHid = $03;
  UsbClassMassStorage = $08;
  UsbClassHub = $09;
  UsbClassVendor = $FF;

  UsbSubclassAudioControl = $01;
  UsbSubclassAudioStreaming = $02;
  UsbSubclassHidBoot = $01;
  UsbProtocolHidKeyboard = $01;
  UsbProtocolHidMouse = $02;

type
  TUsbEndpointInfo = record
    { The endpoint's number, with 80h set for IN. }
    Address: Byte;
    { The transfer type in bits 0-1 (UsbTransfer...). }
    Attributes: Byte;
    MaximumPacket: Word;
    Interval: Byte;
  end;

  PUsbInterfaceInfo = ^TUsbInterfaceInfo;
  TUsbInterfaceInfo = record
    Number: Byte;
    InterfaceClass: Byte;
    Subclass: Byte;
    Protocol: Byte;
    { How many settings it has (1 without alternates). }
    SettingCount: Byte;
    { Setting 0's endpoints. }
    EndpointCount: Integer;
    Endpoints: array[0..MaximumInterfaceEndpoints - 1] of TUsbEndpointInfo;
    { The report descriptor's length from its HID descriptor (0 if it has
      none). }
    HidReportLength: Word;
    { Where its descriptors are in the configuration descriptor: from
      its first interface descriptor to the next interface's (all its
      settings, when they come together as they should). }
    DescriptorOffset: LongWord;
    DescriptorLength: LongWord;
  end;

  TUsbConfigurationInfo = record
    InterfaceCount: Integer;
    Interfaces: array[0..MaximumUsbInterfaces - 1] of TUsbInterfaceInfo;
  end;

{ Walks the configuration descriptor Data (Length bytes). False if it is
  not one or a descriptor in it is cut short (the interfaces before
  that are kept); interfaces past MaximumUsbInterfaces, and endpoints
  past MaximumInterfaceEndpoints, are left out. }
function ParseUsbConfiguration(Data: PByte; Length: LongWord; out Configuration: TUsbConfigurationInfo): Boolean;
{ The interface numbered Number, or nil. }
function FindUsbInterface(var Configuration: TUsbConfigurationInfo; Number: Byte): PUsbInterfaceInfo;
{ The interface's first endpoint of TransferType in the direction asked
  (IN when WantIn). }
function FindUsbEndpoint(const UsbInterface: TUsbInterfaceInfo; TransferType: Byte; WantIn: Boolean;
  out Endpoint: TUsbEndpointInfo): Boolean;
{ True if Address (80h set for IN) names an endpoint other than the
  default control endpoint, without reserved bits. }
function UsbEndpointAddressIsValid(Address: Byte): Boolean;
{ A few words on what an interface of this class, subclass and protocol
  is, for the log ("HID boot mouse"). }
function UsbInterfaceKindName(InterfaceClass, Subclass, Protocol: Byte): PChar;
{ "interrupt", "bulk", "isochronous" or "control". }
function UsbTransferTypeName(Attributes: Byte): PChar;

implementation

uses
  Runtime.Memory;

function ReadWord(Data: PByte): Word;
begin
  Result := Data[0] or (Word(Data[1]) shl 8);
end;

function UsbEndpointAddressIsValid(Address: Byte): Boolean;
begin
  Result := ((Address and $0F) <> 0) and ((Address and $70) = 0);
end;

function HasEndpointAddress(const UsbInterface: TUsbInterfaceInfo; Address: Byte): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to UsbInterface.EndpointCount - 1 do
    if UsbInterface.Endpoints[Index].Address = Address then
      Exit(True);
  Result := False;
end;

{ Adds the endpoint descriptor's endpoint, unless it is one no driver
  may be given (see the unit's header). }
procedure AddEndpoint(var UsbInterface: TUsbInterfaceInfo; Descriptor: PByte);
var
  Endpoint: ^TUsbEndpointInfo;
  Address: Byte;
  MaximumPacket: Word;
begin
  if UsbInterface.EndpointCount = MaximumInterfaceEndpoints then
    Exit;
  Address := Descriptor[2];
  MaximumPacket := ReadWord(Descriptor + 4) and $7FF;
  if not UsbEndpointAddressIsValid(Address) or ((Descriptor[3] and 3) = UsbTransferControl) or
     (MaximumPacket = 0) or HasEndpointAddress(UsbInterface, Address) then
    Exit;
  Endpoint := @UsbInterface.Endpoints[UsbInterface.EndpointCount];
  Endpoint^.Address := Address;
  Endpoint^.Attributes := Descriptor[3];
  Endpoint^.MaximumPacket := MaximumPacket;
  Endpoint^.Interval := Descriptor[6];
  Inc(UsbInterface.EndpointCount);
end;

{ The entry for the interface descriptor at Position (a new one, or the
  one of an earlier setting); nil once the list is full. }
function EntryFor(var Configuration: TUsbConfigurationInfo; Descriptor: PByte; Position: LongWord): PUsbInterfaceInfo;
begin
  Result := FindUsbInterface(Configuration, Descriptor[2]);
  if Result <> nil then
  begin
    Inc(Result^.SettingCount);
    Exit;
  end;
  if Configuration.InterfaceCount = MaximumUsbInterfaces then
    Exit(nil);
  Result := @Configuration.Interfaces[Configuration.InterfaceCount];
  Inc(Configuration.InterfaceCount);
  Result^.Number := Descriptor[2];
  Result^.SettingCount := 1;
  Result^.DescriptorOffset := Position;
end;

function ParseUsbConfiguration(Data: PByte; Length: LongWord; out Configuration: TUsbConfigurationInfo): Boolean;
var
  Position: LongWord;
  DescriptorLength: Byte;
  Kind: Byte;
  Descriptor: PByte;
  Current: PUsbInterfaceInfo;
  { Only setting 0's endpoints and HID descriptor are taken. }
  InFirstSetting: Boolean;
begin
  ZeroMemory(@Configuration, SizeOf(Configuration));
  Result := False;
  if (Data = nil) or (Length < 9) or (Data[0] < 9) or (Data[1] <> UsbDescriptorConfiguration) then
    Exit;
  Current := nil;
  InFirstSetting := False;
  Position := 0;
  while Position + 2 <= Length do
  begin
    Descriptor := Data + Position;
    DescriptorLength := Descriptor[0];
    Kind := Descriptor[1];
    if (DescriptorLength < 2) or (Position + DescriptorLength > Length) then
      Exit;
    if (Kind = UsbDescriptorInterface) and (DescriptorLength >= 9) then
    begin
      Current := EntryFor(Configuration, Descriptor, Position);
      InFirstSetting := (Current <> nil) and (Descriptor[3] = 0);
      if InFirstSetting then
      begin
        Current^.InterfaceClass := Descriptor[5];
        Current^.Subclass := Descriptor[6];
        Current^.Protocol := Descriptor[7];
      end;
    end
    else if InFirstSetting and (Kind = UsbDescriptorEndpoint) and (DescriptorLength >= 7) then
      AddEndpoint(Current^, Descriptor)
    else if InFirstSetting and (Kind = UsbDescriptorHid) and (DescriptorLength >= 9) and
            (Descriptor[6] = UsbDescriptorHidReport) then
      Current^.HidReportLength := ReadWord(Descriptor + 7);
    Position := Position + DescriptorLength;
    if Current <> nil then
      Current^.DescriptorLength := Position - Current^.DescriptorOffset;
  end;
  Result := True;
end;

function FindUsbInterface(var Configuration: TUsbConfigurationInfo; Number: Byte): PUsbInterfaceInfo;
var
  Index: Integer;
begin
  for Index := 0 to Configuration.InterfaceCount - 1 do
    if Configuration.Interfaces[Index].Number = Number then
      Exit(@Configuration.Interfaces[Index]);
  Result := nil;
end;

function FindUsbEndpoint(const UsbInterface: TUsbInterfaceInfo; TransferType: Byte; WantIn: Boolean;
  out Endpoint: TUsbEndpointInfo): Boolean;
var
  Index: Integer;
  IsIn: Boolean;
begin
  for Index := 0 to UsbInterface.EndpointCount - 1 do
  begin
    IsIn := (UsbInterface.Endpoints[Index].Address and $80) <> 0;
    if ((UsbInterface.Endpoints[Index].Attributes and 3) = TransferType) and (IsIn = WantIn) then
    begin
      Endpoint := UsbInterface.Endpoints[Index];
      Exit(True);
    end;
  end;
  ZeroMemory(@Endpoint, SizeOf(Endpoint));
  Result := False;
end;

function HidKindName(Subclass, Protocol: Byte): PChar;
begin
  if Subclass <> UsbSubclassHidBoot then
    Exit('HID');
  case Protocol of
    UsbProtocolHidKeyboard: Result := 'HID boot keyboard';
    UsbProtocolHidMouse: Result := 'HID boot mouse';
  else
    Result := 'HID boot device';
  end;
end;

function AudioKindName(Subclass: Byte): PChar;
begin
  case Subclass of
    UsbSubclassAudioControl: Result := 'audio control';
    UsbSubclassAudioStreaming: Result := 'audio streaming';
    $03: Result := 'MIDI streaming';
  else
    Result := 'audio';
  end;
end;

function UsbInterfaceKindName(InterfaceClass, Subclass, Protocol: Byte): PChar;
begin
  case InterfaceClass of
    UsbClassAudio: Result := AudioKindName(Subclass);
    $02: Result := 'communications';
    UsbClassHid: Result := HidKindName(Subclass, Protocol);
    $06: Result := 'still image';
    $07: Result := 'printer';
    UsbClassMassStorage: Result := 'mass storage';
    UsbClassHub: Result := 'hub';
    $0A: Result := 'communications data';
    $0B: Result := 'smart card';
    $0E: Result := 'video';
    $E0: Result := 'wireless controller';
    $EF: Result := 'miscellaneous';
    $FE: Result := 'application specific';
    UsbClassVendor: Result := 'vendor specific';
  else
    Result := 'unknown class';
  end;
end;

function UsbTransferTypeName(Attributes: Byte): PChar;
begin
  case Attributes and 3 of
    UsbTransferControl: Result := 'control';
    UsbTransferIsochronous: Result := 'isochronous';
    UsbTransferBulk: Result := 'bulk';
  else
    Result := 'interrupt';
  end;
end;

end.
