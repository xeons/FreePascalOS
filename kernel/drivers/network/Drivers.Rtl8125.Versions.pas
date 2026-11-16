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
  The versions of the RTL8125 (2.5 Gbit/s) and RTL8126 (5 Gbit/s), told
  apart as the reference drivers do: by the XID, bits 20-31 of the
  transmit configuration register, masked with 7CFh. Each version has
  the name of the PHY firmware patch Linux loads for it (linux-firmware
  rtl_nic/...). The PCI ID only says which family to look for: the
  Killer E3000 (10EC:3000) is an RTL8125 under another name, the Killer
  E5000 (10EC:5000) an RTL8126.
}
unit Drivers.Rtl8125.Versions;

{$mode objfpc}

interface

type
  { The set-up differs between these (Drivers.Rtl8125.Setup). }
  TRtl8125Generation = (Generation8125A, Generation8125B, Generation8125D, Generation8125BP, Generation8126A);

  PRtl8125Version = ^TRtl8125Version;
  TRtl8125Version = record
    Xid: Word;
    Generation: TRtl8125Generation;
    Name: PChar;
    FirmwareName: PChar;
  end;

const
  Rtl8125XidMask = $7CF;

{ The version with this XID (already masked), or nil. }
function FindRtl8125Version(Xid: Word): PRtl8125Version;
{ For a chip whose XID is not known: the most common version of the
  family its PCI ID belongs to (tried, with a warning). }
function FallbackRtl8125Version(DeviceId: Word): PRtl8125Version;
{ True for the PCI IDs of the RTL8125/8126 family. }
function IsRtl8125Family(VendorId, DeviceId: Word): Boolean;
function IsRtl8126DeviceId(DeviceId: Word): Boolean;

implementation

const
  VersionCount = 7;
  Versions: array[0..VersionCount - 1] of TRtl8125Version = (
    (Xid: $609; Generation: Generation8125A; Name: 'Realtek RTL8125A'; FirmwareName: 'rtl_nic/rtl8125a-3.fw'),
    (Xid: $641; Generation: Generation8125B; Name: 'Realtek RTL8125B'; FirmwareName: 'rtl_nic/rtl8125b-2.fw'),
    (Xid: $688; Generation: Generation8125D; Name: 'Realtek RTL8125D'; FirmwareName: 'rtl_nic/rtl8125d-1.fw'),
    (Xid: $689; Generation: Generation8125D; Name: 'Realtek RTL8125D'; FirmwareName: 'rtl_nic/rtl8125d-2.fw'),
    (Xid: $681; Generation: Generation8125BP; Name: 'Realtek RTL8125BP'; FirmwareName: 'rtl_nic/rtl8125bp-2.fw'),
    (Xid: $649; Generation: Generation8126A; Name: 'Realtek RTL8126A'; FirmwareName: 'rtl_nic/rtl8126a-2.fw'),
    (Xid: $64A; Generation: Generation8126A; Name: 'Realtek RTL8126A'; FirmwareName: 'rtl_nic/rtl8126a-3.fw')
  );
  Fallback8125Index = 1;
  Fallback8126Index = 6;

function FindRtl8125Version(Xid: Word): PRtl8125Version;
var
  Index: Integer;
begin
  for Index := 0 to VersionCount - 1 do
    if Versions[Index].Xid = Xid then
      Exit(@Versions[Index]);
  Result := nil;
end;

function IsRtl8126DeviceId(DeviceId: Word): Boolean;
begin
  Result := (DeviceId = $8126) or (DeviceId = $5000);
end;

function FallbackRtl8125Version(DeviceId: Word): PRtl8125Version;
begin
  if IsRtl8126DeviceId(DeviceId) then
    Result := @Versions[Fallback8126Index]
  else
    Result := @Versions[Fallback8125Index];
end;

function IsRtl8125Family(VendorId, DeviceId: Word): Boolean;
begin
  Result := (VendorId = $10EC) and
    ((DeviceId = $8125) or (DeviceId = $3000) or (DeviceId = $8126) or (DeviceId = $5000));
end;

end.
