{
  Passwords, kept in /etc/shadow (readable by root only).

  Lines are  name:hash:  where hash is empty (no password needed), "!"
  or "*" (locked), or  $sha256$SALT$DIGEST  with SALT 16 hex digits and
  DIGEST the hex SHA-256 of SALT followed by the password, hashed again
  together with the password HashRounds - 1 more times:

    D1 = SHA256(salt + password)
    Dn = SHA256(Dn-1 + password)

  Any fields after the second are kept as they are.
}
unit Util.Passwords;

{$mode objfpc}
{$pointermath on}

interface

const
  ShadowPath = '/etc/shadow';

type
  TPasswordCheck = (PasswordAccepted, PasswordRejected, PasswordLocked, PasswordUnknownUser);

{ Checks Password against the hash stored for user Name. }
function CheckPassword(Name: PChar; Password: PChar): TPasswordCheck;
{ True if user Name needs no password. }
function HasEmptyPassword(Name: PChar): Boolean;
{ Stores a new password for user Name (adding a line if there is none).
  Returns an error code (0 on success). }
function SetPassword(Name: PChar; Password: PChar): LongInt;

{ Prints Prompt to the console (or standard error) and reads a line from
  standard input, without echo when it is the console. Returns nil at end
  of input; the caller frees the text. }
function ReadPassword(Prompt: PChar): PChar;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Console,
  Sys.Errors,
  Sys.Files,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Crypto.Digests,
  Crypto.Random,
  Util.Input;

const
  HashRounds = 1000;
  HashPrefix = '$sha256$';
  SaltBytes = 8;
  LineCapacity = 512;
  LineEnd: PChar = #10;

type
  THashText = array[0..127] of Char;

procedure ComputeHash(Salt: PChar; SaltLength: Integer; Password: PChar; out Hash: THashText);
var
  Context: TDigestContext;
  Digest: TDigestOutput;
  Round: Integer;
begin
  BeginDigest(Context, DigestSha256);
  UpdateDigest(Context, PByte(Salt), SaltLength);
  UpdateDigest(Context, PByte(Password), TextLength(Password));
  FinishDigest(Context, Digest);
  for Round := 2 to HashRounds do
  begin
    BeginDigest(Context, DigestSha256);
    UpdateDigest(Context, @Digest[0], DigestSize(DigestSha256));
    UpdateDigest(Context, PByte(Password), TextLength(Password));
    FinishDigest(Context, Digest);
  end;
  FormatHexBytes(@Digest[0], DigestSize(DigestSha256), @Hash[0]);
end;

function SameBytes(First, Second: PChar; Count: PtrUInt): Boolean;
var
  Index: PtrUInt;
  Difference: Byte;
begin
  { Looks at every byte, so the time taken does not tell how much matched. }
  Difference := 0;
  for Index := 1 to Count do
    Difference := Difference or (Byte(First[Index - 1]) xor Byte(Second[Index - 1]));
  Result := Difference = 0;
end;

{ Finds the line of Name; Lines stays loaded for the caller to free. }
function FindEntry(Name: PChar; var Lines: TLineList; out Hash: PChar; out LineIndex: Integer): Boolean;
var
  Stream: PInputStream;
  Index: Integer;
  NameLength: PtrUInt;
  Line: PChar;
begin
  Result := False;
  Hash := nil;
  LineIndex := -1;
  BeginLineList(Lines);
  Stream := OpenInput(ShadowPath);
  if Stream = nil then
    Exit;
  ReadAllLines(Stream, Lines);
  CloseInput(Stream);
  NameLength := TextLength(Name);
  for Index := 0 to Lines.Count - 1 do
  begin
    Line := Lines.Items[Index];
    if TextStartsWith(Line, Name) and (Line[NameLength] = ':') then
    begin
      Hash := Line + NameLength + 1;
      LineIndex := Index;
      Exit(True);
    end;
  end;
end;

{ Length of the hash field (up to the next ':' or the end). }
function FieldLength(Text: PChar): PtrUInt;
begin
  Result := 0;
  while (Text[Result] <> ':') and (Text[Result] <> #0) do
    Inc(Result);
end;

function CheckPassword(Name: PChar; Password: PChar): TPasswordCheck;
var
  Lines: TLineList;
  Hash: PChar;
  LineIndex: Integer;
  Length: PtrUInt;
  Salt: PChar;
  SaltLength: Integer;
  Computed: THashText;
  Stored: PChar;
begin
  if not FindEntry(Name, Lines, Hash, LineIndex) then
  begin
    FreeLineList(Lines);
    Exit(PasswordUnknownUser);
  end;
  Length := FieldLength(Hash);
  Result := PasswordRejected;
  if Length = 0 then
    Result := PasswordAccepted
  else if (Hash[0] = '!') or (Hash[0] = '*') then
    Result := PasswordLocked
  else if TextStartsWith(Hash, HashPrefix) then
  begin
    Salt := Hash + TextLength(HashPrefix);
    SaltLength := 0;
    while (Salt[SaltLength] <> '$') and (Salt[SaltLength] <> ':') and (Salt[SaltLength] <> #0) do
      Inc(SaltLength);
    if Salt[SaltLength] = '$' then
    begin
      Stored := Salt + SaltLength + 1;
      ComputeHash(Salt, SaltLength, Password, Computed);
      if (FieldLength(Stored) = TextLength(@Computed[0])) and
         SameBytes(Stored, @Computed[0], TextLength(@Computed[0])) then
        Result := PasswordAccepted;
    end;
  end;
  FreeLineList(Lines);
end;

function HasEmptyPassword(Name: PChar): Boolean;
var
  Lines: TLineList;
  Hash: PChar;
  LineIndex: Integer;
begin
  Result := FindEntry(Name, Lines, Hash, LineIndex) and (FieldLength(Hash) = 0);
  FreeLineList(Lines);
end;

function SetPassword(Name: PChar; Password: PChar): LongInt;
var
  Lines: TLineList;
  Hash: PChar;
  LineIndex: Integer;
  SaltBuffer: array[0..SaltBytes - 1] of Byte;
  Salt: array[0..2 * SaltBytes] of Char;
  Computed: THashText;
  Handle: Int64;
  Index: Integer;
  Line: PChar;
  Rest: PChar;
  Builder: TTextBuilder;
begin
  FindEntry(Name, Lines, Hash, LineIndex);
  RandomBytes(@SaltBuffer[0], SaltBytes);
  FormatHexBytes(@SaltBuffer[0], SaltBytes, @Salt[0]);
  ComputeHash(@Salt[0], 2 * SaltBytes, Password, Computed);

  BeginText(Builder);
  AppendText(Builder, Name);
  AppendText(Builder, ':' + HashPrefix);
  AppendText(Builder, @Salt[0]);
  AppendText(Builder, '$');
  AppendText(Builder, @Computed[0]);
  if LineIndex >= 0 then
  begin
    Rest := Hash + FieldLength(Hash);
    AppendText(Builder, Rest);
  end
  else
    AppendText(Builder, ':');

  Handle := OpenFile(ShadowPath, OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
  begin
    DiscardText(Builder);
    FreeLineList(Lines);
    Exit(ErrorCodeOf(Handle));
  end;
  Result := ErrorNone;
  for Index := 0 to Lines.Count - 1 do
  begin
    if Index = LineIndex then
      Line := Builder.Text
    else
      Line := Lines.Items[Index];
    if (WriteFile(Handle, Line, TextLength(Line)) < 0) or (WriteFile(Handle, PChar(LineEnd), 1) < 0) then
      Result := ErrorIo;
  end;
  if LineIndex < 0 then
    if (WriteFile(Handle, Builder.Text, TextLength(Builder.Text)) < 0) or
       (WriteFile(Handle, PChar(LineEnd), 1) < 0) then
      Result := ErrorIo;
  CloseFile(Handle);
  DiscardText(Builder);
  FreeLineList(Lines);
end;

function ReadPassword(Prompt: PChar): PChar;
var
  OnConsole: Boolean;
  OldMode: Int64;
  Line: PChar;
  HadLineEnd: Boolean;
begin
  OnConsole := IsConsole(StandardInputHandle);
  WriteText(StandardError, Prompt);
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

end.
