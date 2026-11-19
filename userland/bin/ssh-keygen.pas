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
  ssh-keygen - makes and shows SSH keys

  ssh-keygen [-q] [-t ed25519|ecdsa] [-b 256] [-f FILE] [-N ''] [-C COMMENT]
  ssh-keygen -l [-f FILE]
  ssh-keygen -y [-f FILE]

  Makes a key pair in OpenSSH's format: the private key in FILE (mode
  0600; ~/.ssh/id_ed25519 or ~/.ssh/id_ecdsa by default) and the public
  key in FILE.pub. Keys have no passphrase (-N must be empty): the
  system has no cipher for key files yet. -l prints the SHA256
  fingerprint of a public or private key file; -y prints the public key
  of a private key file. The protocol pieces are libssh's.
}
program sshkeygen;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Util.CommandLine,
  Util.Messages,
  Ssh.Wire,
  Ssh.Base64,
  Ssh.HostKeys,
  Ssh.KeyFiles,
  Ssh.PublicKeys,
  Ssh.AuthorizedKeys;

const
  Usage = 'Usage: ssh-keygen [-q] [-t ed25519|ecdsa] [-b 256] [-f FILE] [-N ''''] [-C COMMENT]'#10 +
    '       ssh-keygen -l [-f FILE]'#10 +
    '       ssh-keygen -y [-f FILE]'#10;
  OptionType = 1;
  OptionBits = 2;
  OptionFile = 3;
  OptionPassphrase = 4;
  OptionComment = 5;
  OptionFingerprint = 6;
  OptionPublic = 7;
  OptionQuiet = 8;
  PrivateKeyMode = $180;
  PublicKeyMode = $1A4;
  DirectoryMode = $1C0;

var
  KeyType: string = 'ed25519';
  Path: string = '';
  Comment: string = '';
  Fingerprint: Boolean = False;
  ShowPublic: Boolean = False;
  Quiet: Boolean = False;

function ReadText(const FileName: string; out Text: string): Boolean;
var
  Stream: TFileStream;
begin
  Text := '';
  Result := False;
  try
    Stream := TFileStream.Create(FileName, fmOpenRead);
    try
      SetLength(Text, Stream.Size);
      if Stream.Size > 0 then
        Stream.ReadBuffer(Text[1], Stream.Size);
      Result := True;
    finally
      Stream.Free;
    end;
  except
    on Exception do
      Result := False;
  end;
end;

{ Text into a new file whose mode is set before anything is in it. }
function WriteNewFile(const FileName, Text: string; Mode: LongWord): LongInt;
var
  Handle: Int64;
begin
  Handle := OpenFile(PChar(FileName), OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Exit(ErrorCodeOf(Handle));
  Result := ChangeMode(PChar(FileName), Mode);
  if (Result = ErrorNone) and (Text <> '') then
    Result := WriteAll(Handle, @Text[1], Length(Text));
  CloseFile(Handle);
end;

function DefaultPath(const Kind: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + '.ssh/id_' + Kind;
end;

procedure ReadOptions;
var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
begin
  CommandLine := TCommandLine.Create([
    CommandOption('t', '', True, OptionType),
    CommandOption('b', '', True, OptionBits),
    CommandOption('f', '', True, OptionFile),
    CommandOption('N', '', True, OptionPassphrase),
    CommandOption('C', '', True, OptionComment),
    CommandOption('l', '', False, OptionFingerprint),
    CommandOption('y', '', False, OptionPublic),
    CommandOption('q', '', False, OptionQuiet)], Usage);
  try
    while CommandLine.NextOption(Code, Value) do
      case Code of
        OptionType: KeyType := LowerCase(Value);
        OptionBits:
          if Value <> '256' then
            FailWithUsageHint('only 256-bit ecdsa keys are made');
        OptionFile: Path := Value;
        OptionPassphrase:
          if Value <> '' then
            Fail(1, 'passphrases are not supported yet: give -N ''''');
        OptionComment: Comment := Value;
        OptionFingerprint: Fingerprint := True;
        OptionPublic: ShowPublic := True;
        OptionQuiet: Quiet := True;
      end;
    if CommandLine.OperandCount > 0 then
      FailWithUsageHint('no operands are taken');
  finally
    CommandLine.Free;
  end;
  if (KeyType <> 'ed25519') and (KeyType <> 'ecdsa') then
    FailWithUsageHint('unknown key type ' + KeyType + ' (ed25519 or ecdsa)');
  if Path = '' then
    Path := DefaultPath(KeyType);
end;

{ The public key blob of a public or private key file. }
function BlobOfFile(const FileName: string; out Blob, KeyComment: string): Boolean;
var
  Text, Problem: string;
  Key: TSshHostKey;
  Line: TSshAuthorizedKey;
begin
  Blob := '';
  KeyComment := '';
  Result := False;
  if not ReadText(FileName, Text) then
    Exit;
  Key := DecodePrivateKeyFile(Text);
  if Key <> nil then
  begin
    Blob := Key.PublicBlob;
    Key.Free;
    if ReadText(FileName + '.pub', Text) and ParseAuthorizedKeysLine(Trim(Text), Line, Problem) then
      KeyComment := Line.Comment;
    Exit(True);
  end;
  if ParseAuthorizedKeysLine(Trim(Text), Line, Problem) then
  begin
    Blob := Line.Blob;
    KeyComment := Line.Comment;
    Result := True;
  end;
end;

function KindOf(const Blob: string): string;
var
  Reader: TSshReader;
begin
  Reader.Start(Blob);
  Result := Reader.ReadString;
  if Result = 'ssh-ed25519' then
    Result := 'ED25519'
  else if Result = 'ecdsa-sha2-nistp256' then
    Result := 'ECDSA'
  else if Result = 'ssh-rsa' then
    Result := 'RSA';
end;

procedure PrintFingerprint;
var
  Blob, KeyComment: string;
begin
  if not BlobOfFile(Path, Blob, KeyComment) then
    Fail(1, Path + ' is not a key file');
  if KeyComment = '' then
    KeyComment := 'no comment';
  WriteLn('256 ', PublicKeyFingerprint(Blob), ' ', KeyComment, ' (', KindOf(Blob), ')');
end;

procedure PrintPublicKey;
var
  Text: string;
  Key: TSshHostKey;
begin
  if not ReadText(Path, Text) then
    Fail(1, 'cannot read ' + Path);
  Key := DecodePrivateKeyFile(Text);
  WipeString(Text);
  if Key = nil then
    Fail(1, Path + ' is not an unencrypted ed25519 or ecdsa private key');
  WriteLn(PublicKeyLine(Key.PublicBlob, Comment));
  Key.Free;
end;

procedure MakeKey;
var
  Key: TSshHostKey;
  Error: LongInt;
  Directory, Text: string;
begin
  if FileExists(Path) then
    Fail(1, Path + ' already exists');
  Directory := ExtractFileDir(Path);
  if (Directory <> '') and not DirectoryExists(Directory) then
  begin
    CreateDirectory(PChar(Directory));
    ChangeMode(PChar(Directory), DirectoryMode);
  end;
  if Comment = '' then
    Comment := GetEnvironmentVariable('USER') + '@fpos';
  if KeyType = 'ed25519' then
    Key := TSshEd25519HostKey.Generate
  else
    Key := TSshEcdsaP256HostKey.Generate;
  try
    Text := EncodePrivateKeyFile(Key, Comment);
    Error := WriteNewFile(Path, Text, PrivateKeyMode);
    WipeString(Text);
    if Error <> ErrorNone then
      FailWithError(1, Error, 'cannot write ' + Path);
    Error := WriteNewFile(Path + '.pub', PublicKeyLine(Key.PublicBlob, Comment) + #10, PublicKeyMode);
    if Error <> ErrorNone then
      FailWithError(1, Error, 'cannot write ' + Path + '.pub');
    if not Quiet then
    begin
      WriteLn('Your identification has been saved in ', Path);
      WriteLn('Your public key has been saved in ', Path, '.pub');
      WriteLn('The key fingerprint is:');
      WriteLn(PublicKeyFingerprint(Key.PublicBlob), ' ', Comment);
    end;
  finally
    Key.Free;
  end;
end;

begin
  ReadOptions;
  if Fingerprint then
    PrintFingerprint
  else if ShowPublic then
    PrintPublicKey
  else
    MakeKey;
end.
