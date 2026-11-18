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
  The ciphers by name: the ones offered, in order of preference, how
  many key and initial value bytes each takes from the key exchange, and
  making one.
}
unit Ssh.CipherSuites;

{$mode objfpc}{$H+}

interface

uses
  Ssh.PacketCiphers;

const
  SupportedCiphers: array[0..2] of string = (
    'chacha20-poly1305@openssh.com', 'aes256-gcm@openssh.com', 'aes128-gcm@openssh.com');

function CipherIsSupported(const Name: string): Boolean;
function CipherKeySize(const Name: string): Integer;
function CipherInitialValueSize(const Name: string): Integer;
{ Key and InitialValue as long as the two functions above say. }
function CreatePacketCipher(const Name, Key, InitialValue: string): TSshPacketCipher;

implementation

uses
  SysUtils,
  Ssh.Constants,
  Ssh.ChaChaPolyCipher,
  Ssh.AesGcmCipher;

function CipherIsSupported(const Name: string): Boolean;
begin
  Result := (Name = CipherChaCha20Poly1305) or (Name = CipherAes256Gcm) or (Name = CipherAes128Gcm);
end;

function CipherKeySize(const Name: string): Integer;
begin
  if Name = CipherChaCha20Poly1305 then
    Result := ChaChaPolyKeySize
  else if Name = CipherAes256Gcm then
    Result := 32
  else if Name = CipherAes128Gcm then
    Result := 16
  else
    Result := 0;
end;

function CipherInitialValueSize(const Name: string): Integer;
begin
  if (Name = CipherAes256Gcm) or (Name = CipherAes128Gcm) then
    Result := AesGcmInitialValueSize
  else
    Result := 0;
end;

function CreatePacketCipher(const Name, Key, InitialValue: string): TSshPacketCipher;
begin
  if Name = CipherChaCha20Poly1305 then
    Result := TSshChaChaPolyCipher.Create(Key)
  else if (Name = CipherAes256Gcm) or (Name = CipherAes128Gcm) then
    Result := TSshAesGcmCipher.Create(Key, InitialValue)
  else
    raise Exception.Create('unknown cipher ' + Name);
end;

end.
