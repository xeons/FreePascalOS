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
  The secret of the stable-privacy IPv6 interface identifiers (RFC
  7217): 32 random bytes, made once and kept in
  /var/lib/network/stable-secret (64 hexadecimal digits, readable by
  root alone), handed to the kernel when the service starts, so every
  interface gets the same addresses on the same network after each
  restart, and different ones on each network.
}
unit NetworkService.StableSecret;

{$mode objfpc}
{$H+}

interface

{ Reads the secret (making and keeping one the first time) and gives it
  to the kernel. }
procedure ApplyStableSecret;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.RandomNumbers,
  Sys.NetworkInterfaces,
  NetworkService.Log;

const
  SecretPath = '/var/lib/network/stable-secret';
  SecretFileMode = $180;   { rw------- }

type
  TStableSecret = array[0..StableSecretBytes - 1] of Byte;

function ReadSecret(out Secret: TStableSecret): Boolean;
var
  Handle: Int64;
  Text: array[0..StableSecretBytes * 2 - 1] of Char;
  Count: Int64;
  Index: Integer;
  Value: LongInt;
begin
  FillChar(Secret, SizeOf(Secret), 0);
  Handle := OpenFile(SecretPath, OpenRead);
  if Handle < 0 then
    Exit(False);
  Count := ReadFile(Handle, @Text[0], SizeOf(Text));
  CloseFile(Handle);
  if Count <> SizeOf(Text) then
    Exit(False);
  for Index := 0 to StableSecretBytes - 1 do
  begin
    if not TryStrToInt('$' + Text[Index * 2] + Text[Index * 2 + 1], Value) then
      Exit(False);
    Secret[Index] := Byte(Value);
  end;
  Result := True;
end;

function WriteSecret(constref Secret: TStableSecret): LongInt;
var
  Text: string;
  NewPath: string;
  Handle: Int64;
  Index: Integer;
begin
  Text := '';
  for Index := 0 to StableSecretBytes - 1 do
    Text := Text + LowerCase(IntToHex(Secret[Index], 2));
  Text := Text + #10;
  NewPath := SecretPath + '.new';
  Handle := OpenFile(PChar(NewPath), OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Exit(LongInt(-Handle));
  Result := ChangeMode(PChar(NewPath), SecretFileMode);
  if Result = ErrorNone then
    Result := WriteAll(Handle, @Text[1], Length(Text));
  CloseFile(Handle);
  if Result = ErrorNone then
    Result := RenamePath(PChar(NewPath), SecretPath);
  if Result <> ErrorNone then
    RemovePath(PChar(NewPath));
end;

procedure ApplyStableSecret;
var
  Secret: TStableSecret;
  Error: LongInt;
begin
  if not ReadSecret(Secret) then
  begin
    FillRandomBytes(@Secret[0], StableSecretBytes);
    Error := WriteSecret(Secret);
    if Error <> ErrorNone then
      Say('cannot keep the IPv6 stable-privacy secret in ' + SecretPath + ': ' + ErrorText(Error))
    else
      Say('made the IPv6 stable-privacy secret');
  end;
  Error := SetIpv6StableSecret(@Secret[0]);
  if Error <> ErrorNone then
    Say('cannot give the kernel the IPv6 stable-privacy secret: ' + ErrorText(Error));
  FillChar(Secret, SizeOf(Secret), 0);
end;

end.
