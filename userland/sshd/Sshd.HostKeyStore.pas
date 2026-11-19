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
  The host keys on disk. Each HostKey path of the configuration is read
  (an OpenSSH private key file, Ssh.KeyFiles); one that does not exist
  yet is made, its kind told by its name ("ed25519" or "ecdsa" in it),
  and written with mode 0600 (set before the key goes in), with its
  public half next to it in PATH.pub (0644). The directory, /etc/ssh by
  default, belongs to root.
}
unit Sshd.HostKeyStore;

{$mode objfpc}{$H+}

interface

uses
  Ssh.HostKeys;

{ The keys of Paths, made where missing; a path that cannot be read or
  made is logged and left out. Announce logs each key read. }
function LoadOrCreateHostKeys(const Paths: array of string; Announce: Boolean): THostKeyArray;
{ Keys with the host certificates of Paths (HostCertificate: one line
  as ssh-keygen -s writes it) for them in front; a certificate for none
  of the keys is logged and left out. }
function AddHostCertificates(const Keys: THostKeyArray; const Paths: array of string): THostKeyArray;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Ssh.Wire,
  Ssh.KeyFiles,
  Ssh.PublicKeys,
  Ssh.AuthorizedKeys,
  Ssh.Certificates,
  Sshd.Log;

const
  PrivateKeyMode = $180;  { rw------- }
  PublicKeyMode = $1A4;   { rw-r--r-- }
  DirectoryMode = $1ED;   { rwxr-xr-x }
  MaximumKeyFileBytes = 64 * 1024;

function ReadWholeFile(const Path: string; out Text: string): Boolean;
var
  Handle: Int64;
  Buffer: array[0..4095] of Byte;
  Count: Int64;
begin
  Text := '';
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit(False);
  repeat
    Count := ReadFile(Handle, @Buffer[0], SizeOf(Buffer));
    if Count > 0 then
      Text := Text + BytesToString(@Buffer[0], Integer(Count));
  until (Count <= 0) or (Length(Text) > MaximumKeyFileBytes);
  CloseFile(Handle);
  Result := Count = 0;
end;

{ Writes Text into a new Path whose mode is Mode before anything is in
  it. }
function WriteNewFile(const Path, Text: string; Mode: LongWord): LongInt;
var
  Handle: Int64;
begin
  Handle := OpenFile(PChar(Path), OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Exit(ErrorCodeOf(Handle));
  Result := ChangeMode(PChar(Path), Mode);
  if (Result = ErrorNone) and (Text <> '') then
    Result := WriteAll(Handle, @Text[1], Length(Text));
  CloseFile(Handle);
end;

procedure MakeDirectoryOf(const Path: string);
var
  Directory: string;
begin
  Directory := ExtractFileDir(Path);
  if (Directory <> '') and not PathExists(PChar(Directory)) then
    if CreateDirectory(PChar(Directory)) = ErrorNone then
      ChangeMode(PChar(Directory), DirectoryMode);
end;

function CreateHostKey(const Path: string): TSshHostKey;
var
  Name: string;
  Error: LongInt;
begin
  Result := nil;
  Name := LowerCase(ExtractFileName(Path));
  if Pos('ed25519', Name) > 0 then
    Result := TSshEd25519HostKey.Generate
  else if Pos('ecdsa', Name) > 0 then
    Result := TSshEcdsaP256HostKey.Generate
  else
  begin
    LogLine('host key ' + Path + ' is missing, and its name does not say its kind (ed25519 or ecdsa)');
    Exit;
  end;
  MakeDirectoryOf(Path);
  Error := WriteNewFile(Path, EncodePrivateKeyFile(Result, 'root@fpos'), PrivateKeyMode);
  if Error = ErrorNone then
    Error := WriteNewFile(Path + '.pub', PublicKeyLine(Result.PublicBlob, 'root@fpos') + #10, PublicKeyMode);
  if Error <> ErrorNone then
    LogLine('cannot write host key ' + Path + ': ' + ErrorMessage(Error) + ' (used until the server stops)')
  else
    LogLine('made host key ' + Path + ' (' + Result.Algorithm + ' ' + PublicKeyFingerprint(Result.PublicBlob) + ')');
end;

function LoadOrCreateHostKeys(const Paths: array of string; Announce: Boolean): THostKeyArray;
var
  Index: Integer;
  Key: TSshHostKey;
  Text: string;
begin
  Result := nil;
  for Index := 0 to High(Paths) do
  begin
    if PathExists(PChar(Paths[Index])) then
    begin
      Key := nil;
      if ReadWholeFile(Paths[Index], Text) then
        Key := DecodePrivateKeyFile(Text);
      if Key = nil then
        LogLine('cannot read host key ' + Paths[Index])
      else if Announce then
        LogLine('host key ' + Paths[Index] + ' (' + Key.Algorithm + ' ' + PublicKeyFingerprint(Key.PublicBlob) + ')');
    end
    else
      Key := CreateHostKey(Paths[Index]);
    if (Key <> nil) and (FindHostKey(Result, Key.Algorithm) <> nil) then
    begin
      LogLine('host key ' + Paths[Index] + ' left out: a second ' + Key.Algorithm + ' key');
      FreeAndNil(Key);
    end;
    if Key <> nil then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Key;
    end;
  end;
end;

function AddHostCertificates(const Keys: THostKeyArray; const Paths: array of string): THostKeyArray;
var
  Index, KeyIndex: Integer;
  Text, Problem: string;
  Line: TSshAuthorizedKey;
  Certificate: TSshCertificate;
  Certified: TSshHostKey;
begin
  Result := nil;
  for Index := 0 to High(Paths) do
  begin
    Certified := nil;
    if ReadWholeFile(Paths[Index], Text) and ParseAuthorizedKeysLine(Trim(Text), Line, Problem) and
      ParseCertificate(Line.Blob, Certificate) and (Certificate.CertificateType = CertificateTypeHost) then
      for KeyIndex := 0 to High(Keys) do
        if Keys[KeyIndex].PublicBlob = Certificate.Key.Blob then
          Certified := TSshCertifiedHostKey.Create(Keys[KeyIndex], Certificate.KeyType, Certificate.Blob);
    if Certified = nil then
    begin
      LogLine('host certificate ' + Paths[Index] + ' left out: unreadable, not a host certificate, or for no host key');
      Continue;
    end;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Certified;
  end;
  for Index := 0 to High(Keys) do
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Keys[Index];
  end;
end;

end.
