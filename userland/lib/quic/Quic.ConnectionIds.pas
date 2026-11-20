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
  Connection IDs (RFC 9000 section 5.1): 0 to 20 opaque bytes, kept in
  a fixed record so they need no allocation.
}
unit Quic.ConnectionIds;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Quic.Constants;

type
  TQuicConnectionId = record
    Length: Byte;
    Bytes: array[0..MaximumConnectionIdLength - 1] of Byte;
  end;
  PQuicConnectionId = ^TQuicConnectionId;

  TStatelessResetToken = array[0..StatelessResetTokenLength - 1] of Byte;

{ False when Length is more than 20. }
function MakeConnectionId(Data: PByte; Length: PtrUInt; out Id: TQuicConnectionId): Boolean;
function RandomConnectionId(Length: Integer): TQuicConnectionId;
function SameConnectionId(constref First, Second: TQuicConnectionId): Boolean;
function ConnectionIdText(constref Id: TQuicConnectionId): string;

implementation

uses
  Crypto.Random,
  Crypto.Digests;

function MakeConnectionId(Data: PByte; Length: PtrUInt; out Id: TQuicConnectionId): Boolean;
begin
  Id := Default(TQuicConnectionId);
  if Length > MaximumConnectionIdLength then
    Exit(False);
  Id.Length := Length;
  if Length > 0 then
    Move(Data^, Id.Bytes[0], Length);
  Result := True;
end;

function RandomConnectionId(Length: Integer): TQuicConnectionId;
begin
  Result := Default(TQuicConnectionId);
  if Length > MaximumConnectionIdLength then
    Length := MaximumConnectionIdLength;
  Result.Length := Length;
  if Length > 0 then
    RandomBytes(@Result.Bytes[0], Length);
end;

function SameConnectionId(constref First, Second: TQuicConnectionId): Boolean;
begin
  Result := (First.Length = Second.Length) and
    ((First.Length = 0) or (CompareByte(First.Bytes[0], Second.Bytes[0], First.Length) = 0));
end;

function ConnectionIdText(constref Id: TQuicConnectionId): string;
begin
  Result := HexText(@Id.Bytes[0], Id.Length);
end;

end.
