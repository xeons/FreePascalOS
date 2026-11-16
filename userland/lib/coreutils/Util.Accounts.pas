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
  Users and groups, from /etc/passwd and /etc/group.

  Every process runs as a real and an effective user and group, with a
  list of supplementary groups (see CallGetCredentials). The account
  files give those numbers and the owners stored in file systems their
  names, and let chown and su accept names.

  /etc/passwd lines: name:password:uid:gid:comment:home:shell
  /etc/group lines:  name:password:gid:member,member,...

  The files are read when first wanted and read again whenever they
  changed since (their node, size or time differ: Util.AccountFiles
  writes a new file each time), so a program that runs for long, like
  the session manager, sees an account added after it started. A name
  returned earlier stays valid until the files change.
}
unit Util.Accounts;

{$mode objfpc}{$H+}
{$pointermath on}

interface

const
  RootId = 0;
  PasswordFilePath = '/etc/passwd';
  GroupFilePath = '/etc/group';

{ The running program's effective user and group. }
function CurrentUserId: LongWord;
function CurrentGroupId: LongWord;
{ Who started it (su changes both, set-user-ID programs only the
  effective ids). }
function CurrentRealUserId: LongWord;
function CurrentRealGroupId: LongWord;
{ The effective group followed by the supplementary groups, without
  duplicates. Returns the count. }
function CurrentGroups(Groups: PLongWord; Capacity: Integer): Integer; overload;

type
  TIdArray = array of LongWord;

function CurrentGroups: TIdArray; overload;
function ShellOf(UserId: LongWord): PChar;

{ Returns nil if there is no such account. }
function UserNameOf(UserId: LongWord): PChar;
function GroupNameOf(GroupId: LongWord): PChar;
{ The same as strings; False if there is no such account. }
function FindUserName(UserId: LongWord; out Name: string): Boolean;
function FindGroupName(GroupId: LongWord; out Name: string): Boolean;
{ The account's name, or its number when it has none. }
function UserNameOrNumber(UserId: LongWord): string;
function GroupNameOrNumber(GroupId: LongWord): string;
{ Accept names and decimal numbers. }
function FindUserId(Name: PChar; out UserId: LongWord): Boolean; overload;
function FindUserId(const Name: string; out UserId: LongWord): Boolean; overload;
function FindGroupId(Name: PChar; out GroupId: LongWord): Boolean; overload;
function FindGroupId(const Name: string; out GroupId: LongWord): Boolean; overload;
function PrimaryGroupOf(UserId: LongWord; out GroupId: LongWord): Boolean;
function HomeDirectoryOf(UserId: LongWord): PChar;
{ ShellOf, HomeDirectoryOf and FullNameOf as strings. }
function UserShell(UserId: LongWord): string;
function UserHomeDirectory(UserId: LongWord): string;
function UserFullName(UserId: LongWord): string;
{ Number of groups listing UserName as a member, or with it as primary
  group; their ids go to Groups (up to Capacity). }
function GroupsOfUser(UserId: LongWord; Groups: PLongWord; Capacity: Integer): Integer; overload;
function GroupsOfUser(UserId: LongWord): TIdArray; overload;
{ The comment field of a user's account (their full name); '' if none. }
function FullNameOf(UserId: LongWord): PChar;
{ The accounts in the order of the files: Index from 0; False past the
  last. }
function UserAt(Index: Integer; out UserId: LongWord): Boolean;
function GroupAt(Index: Integer; out GroupId: LongWord): Boolean;
{ True if the group lists user Name as a member (its primary members are
  not listed there). }
function GroupListsMember(GroupId: LongWord; Name: PChar): Boolean; overload;
function GroupListsMember(GroupId: LongWord; const Name: string): Boolean; overload;
{ The files are looked at again on the next question, however soon (the
  account editing calls this after writing them). }
procedure RecheckAccountFiles;

implementation

uses
  SysUtils,
  Runtime.Memory,
  Runtime.Text,
  Sys.Files,
  Sys.Time,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Sys.Kernel,
  Abi.SystemCalls,
  Util.Input;

type
  TAccount = record
    Name: PChar;
    Id: LongWord;
    GroupId: LongWord;   { users: primary group }
    Home: PChar;         { users }
    Shell: PChar;        { users }
    FullName: PChar;     { users: the comment field }
    Members: PChar;      { groups: comma separated }
  end;
  PAccount = ^TAccount;

const
  RecheckMilliseconds = 1000;

type
  { What a file was when it was read, to tell when it changed. }
  TFileVersion = record
    Exists: Boolean;
    NodeNumber: QWord;
    Size: QWord;
    ModificationTime: Int64;
  end;

var
  Users: PAccount = nil;
  UserCount: Integer = 0;
  Groups: PAccount = nil;
  GroupCount: Integer = 0;
  Loaded: Boolean = False;
  { The lines the tables point into. }
  UserLines: TLineList;
  GroupLines: TLineList;
  UserFileVersion: TFileVersion;
  GroupFileVersion: TFileVersion;
  { Looking at the files costs two calls, so it is done at most once a
    second (a program asking for many names at once, ls -l, asks once). }
  LastCheck: QWord;
  CheckDue: Boolean = True;

{ Splits Line at ':' in place into at most Capacity fields. }
function SplitFields(Line: PChar; Fields: PPChar; Capacity: Integer): Integer;
var
  Position: PtrUInt;
begin
  Result := 0;
  if Capacity = 0 then
    Exit;
  Fields[0] := Line;
  Result := 1;
  Position := 0;
  while Line[Position] <> #0 do
  begin
    if (Line[Position] = ':') and (Result < Capacity) then
    begin
      Line[Position] := #0;
      Fields[Result] := Line + Position + 1;
      Inc(Result);
    end;
    Inc(Position);
  end;
end;

procedure LoadFile(Path: PChar; IsGroupFile: Boolean; var Table: PAccount; var Count: Integer;
  var Lines: TLineList);
var
  Stream: PInputStream;
  Index: Integer;
  Fields: array[0..6] of PChar;
  FieldCount: Integer;
  Number: Int64;
  Entry: PAccount;
begin
  { A missing file just means no names; it is not worth a message. }
  if not PathExists(Path) then
    Exit;
  Stream := OpenInput(Path);
  if Stream = nil then
    Exit;
  ReadAllLines(Stream, Lines);
  CloseInput(Stream);
  Table := PAccount(AllocateZeroedMemory(QWord(Lines.Count + 1) * SizeOf(TAccount)));
  Count := 0;
  for Index := 0 to Lines.Count - 1 do
  begin
    if (Lines.Items[Index][0] = '#') or (Lines.Items[Index][0] = #0) then
      Continue;
    FieldCount := SplitFields(Lines.Items[Index], @Fields[0], Length(Fields));
    if (FieldCount < 3) or not ParseInteger(Fields[2], Number) then
      Continue;
    Entry := @Table[Count];
    Entry^.Name := Fields[0];
    Entry^.Id := LongWord(Number);
    if IsGroupFile then
    begin
      if FieldCount >= 4 then
        Entry^.Members := Fields[3]
      else
        Entry^.Members := '';
    end
    else
    begin
      if (FieldCount >= 4) and ParseInteger(Fields[3], Number) then
        Entry^.GroupId := LongWord(Number);
      if FieldCount >= 5 then
        Entry^.FullName := Fields[4]
      else
        Entry^.FullName := '';
      if FieldCount >= 6 then
        Entry^.Home := Fields[5]
      else
        Entry^.Home := '/';
      if (FieldCount >= 7) and (Fields[6][0] <> #0) then
        Entry^.Shell := Fields[6]
      else
        Entry^.Shell := '/bin/sh';
    end;
    Inc(Count);
  end;
  { The line texts stay in use by the table until the next reading. }
end;

function VersionOf(Path: PChar): TFileVersion;
var
  Information: TFileInformation;
begin
  FillMemory(@Result, SizeOf(Result), 0);
  if GetFileInformation(Path, Information) <> ErrorNone then
    Exit;
  Result.Exists := True;
  Result.NodeNumber := Information.NodeNumber;
  Result.Size := Information.SizeInBytes;
  Result.ModificationTime := Information.ModificationTime;
end;

function SameVersion(const First, Second: TFileVersion): Boolean;
begin
  Result := (First.Exists = Second.Exists) and (First.NodeNumber = Second.NodeNumber) and
    (First.Size = Second.Size) and (First.ModificationTime = Second.ModificationTime);
end;

procedure ForgetTables;
begin
  FreeMemory(Users);
  FreeMemory(Groups);
  Users := nil;
  Groups := nil;
  UserCount := 0;
  GroupCount := 0;
  FreeLineList(UserLines);
  FreeLineList(GroupLines);
end;

procedure EnsureLoaded;
var
  UserVersion: TFileVersion;
  GroupVersion: TFileVersion;
begin
  if Loaded and not CheckDue and (UptimeMilliseconds - LastCheck < RecheckMilliseconds) then
    Exit;
  CheckDue := False;
  LastCheck := UptimeMilliseconds;
  UserVersion := VersionOf(PasswordFilePath);
  GroupVersion := VersionOf(GroupFilePath);
  if Loaded and SameVersion(UserVersion, UserFileVersion) and SameVersion(GroupVersion, GroupFileVersion) then
    Exit;
  if Loaded then
    ForgetTables
  else
  begin
    BeginLineList(UserLines);
    BeginLineList(GroupLines);
  end;
  Loaded := True;
  UserFileVersion := UserVersion;
  GroupFileVersion := GroupVersion;
  LoadFile(PasswordFilePath, False, Users, UserCount, UserLines);
  LoadFile(GroupFilePath, True, Groups, GroupCount, GroupLines);
end;

var
  Credentials: TAbiCredentials;
  HaveCredentials: Boolean = False;

procedure EnsureCredentials;
begin
  if HaveCredentials then
    Exit;
  if KernelGetCredentials(Credentials) < 0 then
    ZeroMemory(@Credentials, SizeOf(Credentials));
  HaveCredentials := True;
end;

function CurrentUserId: LongWord;
begin
  EnsureCredentials;
  Result := Credentials.EffectiveUserId;
end;

function CurrentGroupId: LongWord;
begin
  EnsureCredentials;
  Result := Credentials.EffectiveGroupId;
end;

function CurrentRealUserId: LongWord;
begin
  EnsureCredentials;
  Result := Credentials.RealUserId;
end;

function CurrentRealGroupId: LongWord;
begin
  EnsureCredentials;
  Result := Credentials.RealGroupId;
end;

function CurrentGroups(Groups: PLongWord; Capacity: Integer): Integer;
var
  Index: LongWord;
  Seen: Integer;
  Duplicate: Boolean;
begin
  EnsureCredentials;
  Result := 0;
  if Capacity < 1 then
    Exit;
  Groups[0] := Credentials.EffectiveGroupId;
  Result := 1;
  Index := 0;
  while (Index < Credentials.GroupCount) and (Result < Capacity) do
  begin
    Duplicate := False;
    for Seen := 0 to Result - 1 do
      if Groups[Seen] = Credentials.Groups[Index] then
        Duplicate := True;
    if not Duplicate then
    begin
      Groups[Result] := Credentials.Groups[Index];
      Inc(Result);
    end;
    Inc(Index);
  end;
end;

function FindById(Table: PAccount; Count: Integer; Id: LongWord): PAccount;
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    if Table[Index].Id = Id then
      Exit(@Table[Index]);
  Result := nil;
end;

function FindByName(Table: PAccount; Count: Integer; Name: PChar): PAccount;
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    if TextIsEqual(Table[Index].Name, Name) then
      Exit(@Table[Index]);
  Result := nil;
end;

function UserNameOf(UserId: LongWord): PChar;
var
  Entry: PAccount;
begin
  EnsureLoaded;
  Entry := FindById(Users, UserCount, UserId);
  if Entry = nil then
    Exit(nil);
  Result := Entry^.Name;
end;

function GroupNameOf(GroupId: LongWord): PChar;
var
  Entry: PAccount;
begin
  EnsureLoaded;
  Entry := FindById(Groups, GroupCount, GroupId);
  if Entry = nil then
    Exit(nil);
  Result := Entry^.Name;
end;

function FindUserId(Name: PChar; out UserId: LongWord): Boolean;
var
  Entry: PAccount;
  Number: Int64;
begin
  EnsureLoaded;
  UserId := 0;
  Entry := FindByName(Users, UserCount, Name);
  if Entry <> nil then
  begin
    UserId := Entry^.Id;
    Exit(True);
  end;
  Result := ParseInteger(Name, Number) and (Number >= 0) and (Number <= High(LongWord));
  if Result then
    UserId := LongWord(Number);
end;

function FindGroupId(Name: PChar; out GroupId: LongWord): Boolean;
var
  Entry: PAccount;
  Number: Int64;
begin
  EnsureLoaded;
  GroupId := 0;
  Entry := FindByName(Groups, GroupCount, Name);
  if Entry <> nil then
  begin
    GroupId := Entry^.Id;
    Exit(True);
  end;
  Result := ParseInteger(Name, Number) and (Number >= 0) and (Number <= High(LongWord));
  if Result then
    GroupId := LongWord(Number);
end;

function PrimaryGroupOf(UserId: LongWord; out GroupId: LongWord): Boolean;
var
  Entry: PAccount;
begin
  EnsureLoaded;
  GroupId := 0;
  Entry := FindById(Users, UserCount, UserId);
  Result := Entry <> nil;
  if Result then
    GroupId := Entry^.GroupId;
end;

function ShellOf(UserId: LongWord): PChar;
var
  Entry: PAccount;
begin
  EnsureLoaded;
  Entry := FindById(Users, UserCount, UserId);
  if Entry = nil then
    Exit('/bin/sh');
  Result := Entry^.Shell;
end;

function HomeDirectoryOf(UserId: LongWord): PChar;
var
  Entry: PAccount;
begin
  EnsureLoaded;
  Entry := FindById(Users, UserCount, UserId);
  if Entry = nil then
    Exit('/');
  Result := Entry^.Home;
end;

{ True if Name appears in the comma separated Members list. }
function IsMember(Members, Name: PChar): Boolean;
var
  Start: PChar;
  Length: PtrUInt;
begin
  Length := TextLength(Name);
  Start := Members;
  while Start^ <> #0 do
  begin
    if TextStartsWith(Start, Name) and ((Start[Length] = ',') or (Start[Length] = #0)) then
      Exit(True);
    while (Start^ <> ',') and (Start^ <> #0) do
      Inc(Start);
    if Start^ = ',' then
      Inc(Start);
  end;
  Result := False;
end;

function GroupsOfUser(UserId: LongWord; Groups: PLongWord; Capacity: Integer): Integer;
var
  Primary: LongWord;
  Name: PChar;
  Index: Integer;
begin
  EnsureLoaded;
  Result := 0;
  if PrimaryGroupOf(UserId, Primary) and (Capacity > 0) then
  begin
    Groups[0] := Primary;
    Result := 1;
  end;
  Name := UserNameOf(UserId);
  if Name = nil then
    Exit;
  for Index := 0 to GroupCount - 1 do
  begin
    if (Result > 0) and (Util.Accounts.Groups[Index].Id = Primary) then
      Continue;
    if IsMember(Util.Accounts.Groups[Index].Members, Name) and (Result < Capacity) then
    begin
      Groups[Result] := Util.Accounts.Groups[Index].Id;
      Inc(Result);
    end;
  end;
end;

procedure RecheckAccountFiles;
begin
  CheckDue := True;
end;

function FullNameOf(UserId: LongWord): PChar;
var
  Entry: PAccount;
begin
  EnsureLoaded;
  Entry := FindById(Users, UserCount, UserId);
  if (Entry = nil) or (Entry^.FullName = nil) then
    Exit('');
  Result := Entry^.FullName;
end;

function UserAt(Index: Integer; out UserId: LongWord): Boolean;
begin
  EnsureLoaded;
  UserId := 0;
  Result := (Index >= 0) and (Index < UserCount);
  if Result then
    UserId := Users[Index].Id;
end;

function GroupAt(Index: Integer; out GroupId: LongWord): Boolean;
begin
  EnsureLoaded;
  GroupId := 0;
  Result := (Index >= 0) and (Index < GroupCount);
  if Result then
    GroupId := Groups[Index].Id;
end;

function GroupListsMember(GroupId: LongWord; Name: PChar): Boolean;
var
  Entry: PAccount;
begin
  EnsureLoaded;
  Entry := FindById(Groups, GroupCount, GroupId);
  Result := (Entry <> nil) and IsMember(Entry^.Members, Name);
end;

{ --- Strings ----------------------------------------------------------- }

const
  { More groups than any account is in. }
  GroupListCapacity = 1024;

function CurrentGroups: TIdArray;
begin
  Result := nil;
  SetLength(Result, GroupListCapacity);
  SetLength(Result, CurrentGroups(@Result[0], GroupListCapacity));
end;

function GroupsOfUser(UserId: LongWord): TIdArray;
begin
  Result := nil;
  SetLength(Result, GroupListCapacity);
  SetLength(Result, GroupsOfUser(UserId, @Result[0], GroupListCapacity));
end;

function FindUserName(UserId: LongWord; out Name: string): Boolean;
var
  Text: PChar;
begin
  Text := UserNameOf(UserId);
  Result := Text <> nil;
  if Result then
    Name := Text
  else
    Name := '';
end;

function FindGroupName(GroupId: LongWord; out Name: string): Boolean;
var
  Text: PChar;
begin
  Text := GroupNameOf(GroupId);
  Result := Text <> nil;
  if Result then
    Name := Text
  else
    Name := '';
end;

function FindUserId(const Name: string; out UserId: LongWord): Boolean;
begin
  Result := FindUserId(PChar(Name), UserId);
end;

function FindGroupId(const Name: string; out GroupId: LongWord): Boolean;
begin
  Result := FindGroupId(PChar(Name), GroupId);
end;

function UserShell(UserId: LongWord): string;
begin
  Result := ShellOf(UserId);
end;

function UserHomeDirectory(UserId: LongWord): string;
begin
  Result := HomeDirectoryOf(UserId);
end;

function UserFullName(UserId: LongWord): string;
begin
  Result := FullNameOf(UserId);
end;

function GroupListsMember(GroupId: LongWord; const Name: string): Boolean;
begin
  Result := GroupListsMember(GroupId, PChar(Name));
end;

function UserNameOrNumber(UserId: LongWord): string;
begin
  if not FindUserName(UserId, Result) then
    Result := IntToStr(UserId);
end;

function GroupNameOrNumber(GroupId: LongWord): string;
begin
  if not FindGroupName(GroupId, Result) then
    Result := IntToStr(GroupId);
end;

end.
