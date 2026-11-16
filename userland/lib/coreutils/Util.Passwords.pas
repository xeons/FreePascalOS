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
  Passwords, kept in /etc/shadow (readable by root only).

  Lines are  name:hash:  where hash is empty (no password needed), "!"
  or "*" (locked), or  $sha256$SALT$DIGEST  with SALT 16 hex digits and
  DIGEST the hex SHA-256 of SALT followed by the password, hashed again
  together with the password HashRounds - 1 more times:

    D1 = SHA256(salt + password)
    Dn = SHA256(Dn-1 + password)

  Any fields after the second are kept as they are.

  Passwords themselves stay in buffers the caller can wipe (a PChar it
  owns): nothing here copies one into a string.
}
unit Util.Passwords;

{$mode objfpc}{$H+}

interface

uses
  Util.AccountFiles;

const
  ShadowPath = '/etc/shadow';

type
  TPasswordCheck = (PasswordAccepted, PasswordRejected, PasswordLocked, PasswordUnknownUser);

{ Checks Password against the hash stored for user Name. }
function CheckPassword(const Name: string; Password: PChar): TPasswordCheck;
{ True if user Name needs no password. }
function HasEmptyPassword(const Name: string): Boolean;
{ Stores a new password for user Name (adding a line if there is none),
  replacing /etc/shadow as Util.AccountFiles does, under the account
  files' lock. Returns an error code (0 on success). }
function SetPassword(const Name: string; Password: PChar): LongInt;
{ The hash field for Password, with a new random salt. }
function NewPasswordHash(Password: PChar): string;
{ Puts Password's hash on Name's line of the shadow file's Lines (a new
  line if there is none), the other fields kept: for programs that edit
  the account files under their lock themselves. }
procedure PutPasswordInLines(var Lines: TAccountLines; const Name: string; Password: PChar);

{ Prints Prompt to the console (or standard error) and reads a line from
  standard input, without echo when it is the console. Returns nil at end
  of input; the caller wipes and frees the text with ForgetPassword. }
function ReadPassword(const Prompt: string): PChar;
{ Overwrites a password ReadPassword returned and frees it (nil is
  allowed). }
procedure ForgetPassword(var Password: PChar);

implementation

uses
  SysUtils,
  StrUtils,
  Abi.SystemCalls,
  Sys.Console,
  Sys.Errors,
  Sys.Memory,
  Sys.Streams,
  Crypto.Digests,
  Crypto.Random,
  Util.Input,
  Util.Numbers;

const
  HashRounds = 1000;
  HashPrefix = '$sha256$';
  SaltBytes = 8;

function ComputeHash(const Salt: string; Password: PChar): string;
var
  Context: TDigestContext;
  Digest: TDigestOutput;
  Round: Integer;
begin
  BeginDigest(Context, DigestSha256);
  UpdateDigest(Context, PByte(PChar(Salt)), Length(Salt));
  UpdateDigest(Context, PByte(Password), StrLen(Password));
  FinishDigest(Context, Digest);
  for Round := 2 to HashRounds do
  begin
    BeginDigest(Context, DigestSha256);
    UpdateDigest(Context, @Digest[0], DigestSize(DigestSha256));
    UpdateDigest(Context, PByte(Password), StrLen(Password));
    FinishDigest(Context, Digest);
  end;
  Result := HexText(Digest, DigestSize(DigestSha256));
end;

{ Looks at every byte, so the time taken does not tell how much matched. }
function SameTextInFixedTime(const First, Second: string): Boolean;
var
  Index: Integer;
  Difference: Byte;
begin
  if Length(First) <> Length(Second) then
    Exit(False);
  Difference := 0;
  for Index := 1 to Length(First) do
    Difference := Difference or (Byte(First[Index]) xor Byte(Second[Index]));
  Result := Difference = 0;
end;

{ The hash field of Name's line (up to the next ':' or the end); False
  if the file cannot be read or has no line for Name. }
function FindHash(const Name: string; out Hash: string): Boolean;
var
  Stream: PInputStream;
  Line: string;
  HadLineEnd: Boolean;
  FieldEnd: Integer;
begin
  Hash := '';
  Stream := OpenInput(ShadowPath);
  if Stream = nil then
    Exit(False);
  Result := False;
  while ReadTextLine(Stream, Line, HadLineEnd) do
    if StartsStr(Name + ':', Line) then
    begin
      Hash := Copy(Line, Length(Name) + 2, MaxInt);
      FieldEnd := Pos(':', Hash);
      if FieldEnd > 0 then
        SetLength(Hash, FieldEnd - 1);
      Result := True;
      Break;
    end;
  CloseInput(Stream);
end;

function CheckPassword(const Name: string; Password: PChar): TPasswordCheck;
var
  Hash: string;
  SaltAndDigest: string;
  SaltEnd: Integer;
begin
  if not FindHash(Name, Hash) then
    Exit(PasswordUnknownUser);
  Result := PasswordRejected;
  if Hash = '' then
    Result := PasswordAccepted
  else if (Hash[1] = '!') or (Hash[1] = '*') then
    Result := PasswordLocked
  else if StartsStr(HashPrefix, Hash) then
  begin
    SaltAndDigest := Copy(Hash, Length(HashPrefix) + 1, MaxInt);
    SaltEnd := Pos('$', SaltAndDigest);
    if (SaltEnd > 0) and SameTextInFixedTime(Copy(SaltAndDigest, SaltEnd + 1, MaxInt),
      ComputeHash(Copy(SaltAndDigest, 1, SaltEnd - 1), Password)) then
      Result := PasswordAccepted;
  end;
end;

function HasEmptyPassword(const Name: string): Boolean;
var
  Hash: string;
begin
  Result := FindHash(Name, Hash) and (Hash = '');
end;

function NewPasswordHash(Password: PChar): string;
var
  SaltBuffer: array[0..SaltBytes - 1] of Byte;
  Salt: string;
begin
  RandomBytes(@SaltBuffer[0], SaltBytes);
  Salt := HexText(SaltBuffer, SaltBytes);
  Result := HashPrefix + Salt + '$' + ComputeHash(Salt, Password);
end;

procedure PutPasswordInLines(var Lines: TAccountLines; const Name: string; Password: PChar);
var
  LineIndex: Integer;
  Fields: TAccountFields;
begin
  LineIndex := FindAccountLine(Lines, Name);
  if LineIndex < 0 then
  begin
    AppendAccountLine(Lines, Name + ':' + NewPasswordHash(Password) + ':');
    Exit;
  end;
  Fields := SplitAccountLine(Lines[LineIndex]);
  if Length(Fields) < 2 then
    SetLength(Fields, 2);
  Fields[1] := NewPasswordHash(Password);
  Lines[LineIndex] := JoinAccountFields(Fields);
end;

function SetPassword(const Name: string; Password: PChar): LongInt;
var
  Lock: Int64;
  Lines: TAccountLines;
begin
  Lock := LockAccountFiles;
  if Lock < 0 then
    Exit(ErrorCodeOf(Lock));
  Result := ReadAccountFile(ShadowPath, Lines);
  if Result = ErrorNotFound then
    Result := ErrorNone;
  if Result = ErrorNone then
  begin
    PutPasswordInLines(Lines, Name, Password);
    Result := WriteAccountFile(ShadowPath, Lines, ShadowFileMode);
  end;
  UnlockAccountFiles(Lock);
end;

function ReadPassword(const Prompt: string): PChar;
var
  OnConsole: Boolean;
  OldMode: Int64;
  Line: PChar;
  HadLineEnd: Boolean;
begin
  OnConsole := IsConsole(StandardInputHandle);
  WriteText(StandardError, PChar(Prompt));
  FlushStream(StandardError);
  OldMode := 0;
  if OnConsole then
  begin
    OldMode := GetConsoleMode(StandardInputHandle);
    if OldMode >= 0 then
      SetConsoleMode(StandardInputHandle, LongWord(OldMode) and not ConsoleModeEcho);
  end;
  if not ReadLine(StandardInput, Line, HadLineEnd) then
    Line := nil;
  if OnConsole and (OldMode >= 0) then
  begin
    SetConsoleMode(StandardInputHandle, LongWord(OldMode));
    WriteCharacter(StandardError, #10);
    FlushStream(StandardError);
  end;
  Result := Line;
end;

procedure ForgetPassword(var Password: PChar);
begin
  if Password = nil then
    Exit;
  FillChar(Password^, StrLen(Password), 0);
  FreeMemory(Password);
  Password := nil;
end;

end.
