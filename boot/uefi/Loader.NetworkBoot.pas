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
  Network boot: where the boot files come from when they come from a
  server.

  The loader boots from the network
    - when the firmware loaded it by HTTP boot: the loader's device path
      ends in the URI it was fetched from;
    - when the firmware loaded it by PXE (TFTP): the PXE client holds the
      DHCP answer with the server's address and the boot file's name;
    - when the options file on the boot volume says netboot=URL, where
      URL is http://host[:port]/path/ or tftp://a.b.c.d/path/.
  The base URL is the directory that holds EFI/ and FreePascalOS/ on the
  server (a boot file named .../EFI/BOOT/BOOTAA64.EFI gives the part
  before EFI/), and boot files are named relative to it
  ("FreePascalOS/kernel.elf").
}
unit Loader.NetworkBoot;

{$mode objfpc}

interface

uses
  Uefi.Base,
  Loader.FileLoading;

{ Decides whether to boot from the network: looks at how the loader was
  started, then for netboot= in CommandLine. }
function DetectNetworkBoot(CommandLine: PChar): Boolean;

{ Opens the network interface (and gets an address). }
function StartNetworkBoot: TEfiStatus;

{ Reads RelativePath (for example 'FreePascalOS/kernel.elf') from the
  server. EfiNotFound if it has no such file. }
function FetchNetworkBootFile(RelativePath: PChar; MemoryType: LongWord;
  out LoadedFile: TLoadedFile): TEfiStatus;

{ The base URL, ending in '/'. }
function NetworkBootBaseUrl: PChar;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Uefi.DevicePath,
  Uefi.LoadedImage,
  Uefi.PxeBaseCode,
  Loader.Firmware,
  Loader.Console,
  Loader.Options,
  Loader.NetworkInterface,
  Loader.HttpTransfer,
  Loader.TftpTransfer;

const
  MaximumUrlLength = 256;
  HttpScheme = 'http://';
  TftpScheme = 'tftp://';

type
  TTransferProtocol = (TransferHttp, TransferTftp);

var
  BaseUrl: array[0..MaximumUrlLength - 1] of Char;
  Protocol: TTransferProtocol;
  { TFTP: the server and the base path on it (no leading '/'). }
  ServerAddress: array[0..3] of Byte;
  TftpBasePath: PChar;
  NetworkInterface: TNetworkInterface;

function NetworkBootBaseUrl: PChar;
begin
  Result := @BaseUrl[0];
end;

function LowerCase(Character: Char): Char;
begin
  if Character in ['A'..'Z'] then
    Result := Char(Ord(Character) + 32)
  else
    Result := Character;
end;

function StartsWithIgnoringCase(Text, Prefix: PChar): Boolean;
begin
  while (Prefix^ <> #0) and (LowerCase(Text^) = LowerCase(Prefix^)) do
  begin
    Inc(Text);
    Inc(Prefix);
  end;
  Result := Prefix^ = #0;
end;

{ Parses a dotted IPv4 address; Text then points after it. }
function ParseIpv4Address(var Text: PChar; out Address: array of Byte): Boolean;
var
  Part: Integer;
  Value: LongWord;
  Digits: Integer;
begin
  Result := False;
  for Part := 0 to 3 do
  begin
    if Part > 0 then
    begin
      if Text^ <> '.' then
        Exit;
      Inc(Text);
    end;
    Value := 0;
    Digits := 0;
    while (Text^ in ['0'..'9']) and (Digits < 4) do
    begin
      Value := Value * 10 + LongWord(Ord(Text^) - Ord('0'));
      Inc(Text);
      Inc(Digits);
    end;
    if (Digits = 0) or (Value > 255) then
      Exit;
    Address[Part] := Byte(Value);
  end;
  Result := True;
end;

{ Keeps Url as the base URL, adding the final '/' if it is missing. }
function SetBaseUrl(Url: PChar; Length: PtrUInt): Boolean;
var
  Host: PChar;
begin
  Result := False;
  if (Length = 0) or (Length + 2 > MaximumUrlLength) then
    Exit;
  CopyMemory(@BaseUrl[0], Url, Length);
  BaseUrl[Length] := #0;
  if BaseUrl[Length - 1] <> '/' then
  begin
    BaseUrl[Length] := '/';
    BaseUrl[Length + 1] := #0;
  end;

  if StartsWithIgnoringCase(@BaseUrl[0], HttpScheme) then
  begin
    Protocol := TransferHttp;
    Result := BaseUrl[TextLength(HttpScheme)] <> '/';
  end
  else if StartsWithIgnoringCase(@BaseUrl[0], TftpScheme) then
  begin
    Protocol := TransferTftp;
    Host := @BaseUrl[TextLength(TftpScheme)];
    if not ParseIpv4Address(Host, ServerAddress) or (Host^ <> '/') then
    begin
      PrintLine('Network boot: a tftp:// URL needs an IPv4 address');
      Exit;
    end;
    TftpBasePath := Host + 1;
    Result := True;
  end
  else
    PrintLine('Network boot: the URL must start with http:// or tftp://');
end;

{ The length of the directory part of a boot file's path: up to EFI/
  if it has one, otherwise up to its last '/'. }
function BaseLengthOfBootFile(Path: PChar; Length: PtrUInt): PtrUInt;
var
  Index: PtrUInt;
begin
  Index := 0;
  while Index + 4 <= Length do
  begin
    if ((Index = 0) or (Path[Index - 1] = '/')) and StartsWithIgnoringCase(Path + Index, 'efi/') then
      Exit(Index);
    Inc(Index);
  end;
  Result := Length;
  while (Result > 0) and (Path[Result - 1] <> '/') do
    Dec(Result);
end;

function LoaderDeviceHandle: TEfiHandle;
var
  LoadedImage: PEfiLoadedImageProtocol;
begin
  Result := nil;
  if not EfiIsError(FirmwareBootServices^.HandleProtocol(LoaderImageHandle,
       @LoadedImageProtocolGuid, @LoadedImage)) then
    Result := LoadedImage^.DeviceHandle;
end;

function DetectHttpBoot: Boolean;
var
  UriNode: PEfiDevicePathNode;
  Uri: PChar;
  UriLength: PtrUInt;
begin
  Result := False;
  UriNode := FindDevicePathNode(LoaderDevicePath, DevicePathTypeMessaging, DevicePathSubTypeUri);
  if UriNode = nil then
    Exit;
  Uri := PChar(UriNode) + SizeOf(TEfiDevicePathNode);
  UriLength := DevicePathNodeLength(UriNode) - SizeOf(TEfiDevicePathNode);
  if UriLength = 0 then
    Exit;
  Result := SetBaseUrl(Uri, BaseLengthOfBootFile(Uri, UriLength));
  if Result then
    PrintLine('Network boot: the loader came by HTTP boot');
end;

{ The PXE answer that named the boot file: the DHCP acknowledgement, or
  a proxy DHCP offer. }
function PxeBootPacket(Mode: PEfiPxeBaseCodeMode): PByte;
begin
  Result := nil;
  if (Mode^.DhcpAckReceived <> 0) and (Mode^.DhcpAck[BootpBootFileOffset] <> 0) then
    Result := @Mode^.DhcpAck[0]
  else if (Mode^.ProxyOfferReceived <> 0) and (Mode^.ProxyOffer[BootpBootFileOffset] <> 0) then
    Result := @Mode^.ProxyOffer[0]
  else if (Mode^.PxeReplyReceived <> 0) and (Mode^.PxeReply[BootpBootFileOffset] <> 0) then
    Result := @Mode^.PxeReply[0];
end;

procedure AppendDecimal(var Url: array of Char; var Length: PtrUInt; Value: Byte);
var
  NumberText: TNumberText;
  Digits: PChar;
begin
  Digits := FormatDecimal(Value, NumberText);
  while Digits^ <> #0 do
  begin
    Url[Length] := Digits^;
    Inc(Length);
    Inc(Digits);
  end;
end;

function DetectPxeBoot: Boolean;
var
  Pxe: PEfiPxeBaseCodeProtocol;
  Packet: PByte;
  BootFile: PChar;
  BootFileLength: PtrUInt;
  Url: array[0..MaximumUrlLength - 1] of Char;
  Length: PtrUInt;
  Index: Integer;
  BaseLength: PtrUInt;
begin
  Result := False;
  if (LoaderDeviceHandle = nil) or EfiIsError(FirmwareBootServices^.HandleProtocol(
       LoaderDeviceHandle, @PxeBaseCodeProtocolGuid, @Pxe)) then
    Exit;
  if (Pxe^.Mode = nil) or (Pxe^.Mode^.Started = 0) or (Pxe^.Mode^.UsingIpv6 <> 0) then
    Exit;
  Packet := PxeBootPacket(Pxe^.Mode);
  if Packet = nil then
    Exit;

  Length := 0;
  CopyText(@Url[0], TftpScheme, MaximumUrlLength);
  Length := TextLength(TftpScheme);
  for Index := 0 to 3 do
  begin
    if Index > 0 then
    begin
      Url[Length] := '.';
      Inc(Length);
    end;
    AppendDecimal(Url, Length, Packet[BootpServerAddressOffset + Index]);
  end;
  Url[Length] := '/';
  Inc(Length);

  BootFile := PChar(Packet + BootpBootFileOffset);
  BootFileLength := 0;
  while (BootFileLength < BootpBootFileLength) and (BootFile[BootFileLength] <> #0) do
    Inc(BootFileLength);
  while (BootFileLength > 0) and (BootFile^ = '/') do
  begin
    Inc(BootFile);
    Dec(BootFileLength);
  end;
  BaseLength := BaseLengthOfBootFile(BootFile, BootFileLength);
  if Length + BaseLength + 2 > MaximumUrlLength then
    Exit;
  CopyMemory(@Url[Length], BootFile, BaseLength);
  Length := Length + BaseLength;
  Result := SetBaseUrl(@Url[0], Length);
  if Result then
    PrintLine('Network boot: the loader came by PXE');
end;

function DetectNetworkBoot(CommandLine: PChar): Boolean;
var
  Url: array[0..MaximumUrlLength - 1] of Char;
begin
  BaseUrl[0] := #0;
  Result := DetectHttpBoot or DetectPxeBoot;
  if (not Result) and FindOptionValue(CommandLine, 'netboot', @Url[0], MaximumUrlLength) then
  begin
    Result := SetBaseUrl(@Url[0], TextLength(@Url[0]));
    if Result then
      PrintLine('Network boot: asked for by netboot= in options.txt');
  end;
  if Result then
  begin
    PrintText('Network boot: files from ');
    PrintLine(@BaseUrl[0]);
  end;
end;

function StartNetworkBoot: TEfiStatus;
begin
  Result := OpenNetworkInterface(NetworkInterface);
end;

function FetchNetworkBootFile(RelativePath: PChar; MemoryType: LongWord;
  out LoadedFile: TLoadedFile): TEfiStatus;
var
  Location: array[0..2 * MaximumUrlLength - 1] of Char;
  UsedLength: PtrUInt;
begin
  if Protocol = TransferHttp then
    CopyText(@Location[0], @BaseUrl[0], Length(Location))
  else
    CopyText(@Location[0], TftpBasePath, Length(Location));
  UsedLength := TextLength(@Location[0]);
  CopyText(@Location[UsedLength], RelativePath, Length(Location) - UsedLength);

  if Protocol = TransferHttp then
    Result := FetchFileOverHttp(NetworkInterface, @Location[0], MemoryType, LoadedFile)
  else
    Result := FetchFileOverTftp(NetworkInterface, ServerAddress, @Location[0], MemoryType,
      LoadedFile);
end;

end.
