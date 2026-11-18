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
  File attributes in SFTP form (ATTRS): from a file's information (size,
  owner and group, the POSIX mode with its type bits, the access and
  modification times), the changes a SETSTAT asks for and applying them,
  and the "ls -l" line READDIR gives with each name.
}
unit Sftp.Attributes;

{$mode objfpc}{$H+}

interface

uses
  Abi.SystemCalls,
  Ssh.Wire;

type
  TSftpAttributes = record
    Flags: LongWord;
    Size: QWord;
    OwnerId, GroupId: LongWord;
    Permissions: LongWord;
    AccessTime, ModificationTime: LongWord;
  end;

function EncodeAttributes(constref Information: TAbiFileInformation): string;
function EmptyAttributes: string;
{ Raises ESshProtocolError for malformed attributes. }
function ReadAttributes(var Reader: TSshReader): TSftpAttributes;
{ Applies the attributes to Path; 0 or an error code. }
function ApplyAttributes(const Path: string; constref Attributes: TSftpAttributes): LongInt;
{ "-rw-r--r--    1 user     user         1234 Nov 17 18:04 name" }
function LongName(const Name: string; constref Information: TAbiFileInformation): string;

implementation

uses
  SysUtils,
  DateUtils,
  Sys.Errors,
  Sys.Files,
  Util.Accounts,
  Util.Modes,
  Sftp.Protocol;

function TypeBits(Kind: LongWord): LongWord;
begin
  case Kind of
    KindDirectory: Result := ModeTypeDirectory;
    KindSymbolicLink: Result := ModeTypeSymbolicLink;
    KindFifo: Result := ModeTypeFifo;
    KindCharacterDevice: Result := ModeTypeCharacterDevice;
    KindBlockDevice: Result := ModeTypeBlockDevice;
  else
    Result := ModeTypeRegular;
  end;
end;

function TypeLetter(Kind: LongWord): Char;
begin
  case Kind of
    KindDirectory: Result := 'd';
    KindSymbolicLink: Result := 'l';
    KindFifo: Result := 'p';
    KindCharacterDevice: Result := 'c';
    KindBlockDevice: Result := 'b';
  else
    Result := '-';
  end;
end;

function TimeValue(Seconds: Int64): LongWord;
begin
  if Seconds < 0 then
    Result := 0
  else if Seconds > High(LongWord) then
    Result := High(LongWord)
  else
    Result := LongWord(Seconds);
end;

function EncodeAttributes(constref Information: TAbiFileInformation): string;
begin
  Result := SshUInt32(AttributeSize or AttributeOwners or AttributePermissions or AttributeTimes) +
    SshUInt64(Information.SizeInBytes) + SshUInt32(Information.OwnerId) + SshUInt32(Information.GroupId) +
    SshUInt32(TypeBits(Information.Kind) or (Information.Mode and $FFF)) +
    SshUInt32(TimeValue(Information.AccessTime)) + SshUInt32(TimeValue(Information.ModificationTime));
end;

function EmptyAttributes: string;
begin
  Result := SshUInt32(0);
end;

function ReadAttributes(var Reader: TSshReader): TSftpAttributes;
var
  Count, Index: LongWord;
begin
  Result := Default(TSftpAttributes);
  Result.Flags := Reader.ReadUInt32;
  if (Result.Flags and AttributeSize) <> 0 then
    Result.Size := Reader.ReadUInt64;
  if (Result.Flags and AttributeOwners) <> 0 then
  begin
    Result.OwnerId := Reader.ReadUInt32;
    Result.GroupId := Reader.ReadUInt32;
  end;
  if (Result.Flags and AttributePermissions) <> 0 then
    Result.Permissions := Reader.ReadUInt32;
  if (Result.Flags and AttributeTimes) <> 0 then
  begin
    Result.AccessTime := Reader.ReadUInt32;
    Result.ModificationTime := Reader.ReadUInt32;
  end;
  if (Result.Flags and AttributeExtended) <> 0 then
  begin
    Count := Reader.ReadUInt32;
    Index := 0;
    while Index < Count do
    begin
      Reader.ReadString;
      Reader.ReadString;
      Inc(Index);
    end;
  end;
end;

function TruncateFile(const Path: string; Size: QWord): LongInt;
var
  Handle: Int64;
begin
  Handle := OpenFile(PChar(Path), OpenWrite);
  if Handle < 0 then
    Exit(ErrorCodeOf(Handle));
  Result := SetFileSize(Handle, Size);
  CloseFile(Handle);
end;

function ApplyAttributes(const Path: string; constref Attributes: TSftpAttributes): LongInt;
begin
  Result := ErrorNone;
  if (Attributes.Flags and AttributeSize) <> 0 then
    Result := TruncateFile(Path, Attributes.Size);
  if (Result = ErrorNone) and ((Attributes.Flags and AttributePermissions) <> 0) then
    Result := ChangeMode(PChar(Path), Attributes.Permissions and $FFF);
  if (Result = ErrorNone) and ((Attributes.Flags and AttributeOwners) <> 0) then
    Result := ChangeOwner(PChar(Path), Attributes.OwnerId, Attributes.GroupId, True);
  if (Result = ErrorNone) and ((Attributes.Flags and AttributeTimes) <> 0) then
    Result := SetFileTimes(PChar(Path), Attributes.ModificationTime, Attributes.AccessTime, True);
end;

function LongName(const Name: string; constref Information: TAbiFileInformation): string;
var
  When: TDateTime;
begin
  When := UnixToDateTime(Information.ModificationTime);
  Result := Format('%s%s %4d %-8s %-8s %12d %s %s', [TypeLetter(Information.Kind),
    FormatModeText(Information.Mode), Information.LinkCount, UserNameOrNumber(Information.OwnerId),
    GroupNameOrNumber(Information.GroupId), Information.SizeInBytes, FormatDateTime('mmm dd hh:nn', When), Name]);
end;

end.
