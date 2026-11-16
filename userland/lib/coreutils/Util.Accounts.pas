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
  the session manager, sees an account added after it started.
}
unit Util.Accounts;

{$mode objfpc}{$H+}

interface

const
  RootId = 0;
  PasswordFilePath = '/etc/passwd';
  GroupFilePath = '/etc/group';

type
  TIdArray = array of LongWord;

{ The running program's effective user and group. }
function CurrentUserId: LongWord;
function CurrentGroupId: LongWord;
{ Who started it (su changes both, set-user-ID programs only the
  effective ids). }
function CurrentRealUserId: LongWord;
function CurrentRealGroupId: LongWord;
{ The effective group followed by the supplementary groups, without
  duplicates. }
function CurrentGroups: TIdArray;

{ An account's name; False (Name empty) if there is no such account. }
function FindUserName(UserId: LongWord; out Name: string): Boolean;
function FindGroupName(GroupId: LongWord; out Name: string): Boolean;
{ The account's name, or its number when it has none. }
function UserNameOrNumber(UserId: LongWord): string;
function GroupNameOrNumber(GroupId: LongWord): string;
{ Accept names and decimal numbers. }
function FindUserId(const Name: string; out UserId: LongWord): Boolean;
function FindGroupId(const Name: string; out GroupId: LongWord): Boolean;
function PrimaryGroupOf(UserId: LongWord; out GroupId: LongWord): Boolean;
{ A user's shell ("/bin/sh" without one) and home directory ("/" for an
  unknown user). }
function UserShell(UserId: LongWord): string;
function UserHomeDirectory(UserId: LongWord): string;
{ The comment field of a user's account (their full name); '' if none. }
function UserFullName(UserId: LongWord): string;
{ The groups listing the user as a member, after the user's primary
  group. }
function GroupsOfUser(UserId: LongWord): TIdArray;
{ The accounts in the order of the files: Index from 0; False past the
  last. }
function UserAt(Index: Integer; out UserId: LongWord): Boolean;
function GroupAt(Index: Integer; out GroupId: LongWord): Boolean;
{ True if the group lists user Name as a member (its primary members are
  not listed there). }
function GroupListsMember(GroupId: LongWord; const Name: string): Boolean;
{ The files are looked at again on the next question, however soon (the
  account editing calls this after writing them). }
procedure RecheckAccountFiles;

implementation

uses
  SysUtils,
  StrUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Kernel,
  Sys.Streams,
  Sys.Time,
  Util.Input,
  Util.Numbers;

type
  TAccount = record
    Name: string;
    Id: LongWord;
    GroupId: LongWord;   { users: primary group }
    Home: string;        { users }
    Shell: string;       { users }
    FullName: string;    { users: the comment field }
    Members: string;     { groups: comma separated }
  end;
  PAccount = ^TAccount;
  TAccountTable = array of TAccount;

const
  RecheckMilliseconds = 1000;
  { name:password:uid:gid:comment:home:shell }
  UserFieldCount = 7;

type
  { What a file was when it was read, to tell when it changed. }
  TFileVersion = record
    Exists: Boolean;
    NodeNumber: QWord;
    Size: QWord;
    ModificationTime: Int64;
  end;

var
  Users: TAccountTable;
  Groups: TAccountTable;
  Loaded: Boolean = False;
  UserFileVersion: TFileVersion;
  GroupFileVersion: TFileVersion;
  { Looking at the files costs two calls, so it is done at most once a
    second (a program asking for many names at once, ls -l, asks once). }
  LastCheck: QWord;
  CheckDue: Boolean = True;

{ Splits Line at ':' into at most Capacity fields (the last one keeps
  any further colons). }
function SplitFields(const Line: string; Capacity: Integer): TStringArray;
var
  Start: Integer;
  Position: Integer;
begin
  Result := nil;
  Start := 1;
  for Position := 1 to Length(Line) do
    if (Line[Position] = ':') and (Length(Result) < Capacity - 1) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(Line, Start, Position - Start);
      Start := Position + 1;
    end;
  SetLength(Result, Length(Result) + 1);
  Result[High(Result)] := Copy(Line, Start, MaxInt);
end;

{ The field at Index, or Default when the line has fewer fields. }
function FieldOr(const Fields: TStringArray; Index: Integer; const Default: string): string;
begin
  if Index < Length(Fields) then
    Result := Fields[Index]
  else
    Result := Default;
end;

{ An account from one line; False for a line that is not one. }
function ParseAccount(const Line: string; IsGroupFile: Boolean; out Account: TAccount): Boolean;
var
  Fields: TStringArray;
  Number: Int64;
begin
  Account := Default(TAccount);
  if (Line = '') or (Line[1] = '#') then
    Exit(False);
  Fields := SplitFields(Line, UserFieldCount);
  if (Length(Fields) < 3) or not ParseDecimal(Fields[2], Number) then
    Exit(False);
  Account.Name := Fields[0];
  Account.Id := LongWord(Number);
  if IsGroupFile then
    Account.Members := FieldOr(Fields, 3, '')
  else
  begin
    if (Length(Fields) >= 4) and ParseDecimal(Fields[3], Number) then
      Account.GroupId := LongWord(Number);
    Account.FullName := FieldOr(Fields, 4, '');
    Account.Home := FieldOr(Fields, 5, '/');
    Account.Shell := FieldOr(Fields, 6, '');
    if Account.Shell = '' then
      Account.Shell := '/bin/sh';
  end;
  Result := True;
end;

function LoadFile(const Path: string; IsGroupFile: Boolean): TAccountTable;
var
  Stream: PInputStream;
  Line: string;
  HadLineEnd: Boolean;
  Account: TAccount;
begin
  Result := nil;
  { A missing file just means no names; it is not worth a message. }
  if not PathExists(PChar(Path)) then
    Exit;
  Stream := OpenInput(Path);
  if Stream = nil then
    Exit;
  while ReadTextLine(Stream, Line, HadLineEnd) do
    if ParseAccount(Line, IsGroupFile, Account) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Account;
    end;
  CloseInput(Stream);
end;

function VersionOf(const Path: string): TFileVersion;
var
  Information: TFileInformation;
begin
  Result := Default(TFileVersion);
  if GetFileInformation(PChar(Path), Information) <> ErrorNone then
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
  Loaded := True;
  UserFileVersion := UserVersion;
  GroupFileVersion := GroupVersion;
  Users := LoadFile(PasswordFilePath, False);
  Groups := LoadFile(GroupFilePath, True);
end;

var
  Credentials: TAbiCredentials;
  HaveCredentials: Boolean = False;

procedure EnsureCredentials;
begin
  if HaveCredentials then
    Exit;
  if KernelGetCredentials(Credentials) < 0 then
    Credentials := Default(TAbiCredentials);
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

function ContainsId(const Ids: TIdArray; Id: LongWord): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Ids) do
    if Ids[Index] = Id then
      Exit(True);
  Result := False;
end;

procedure AppendId(var Ids: TIdArray; Id: LongWord);
begin
  SetLength(Ids, Length(Ids) + 1);
  Ids[High(Ids)] := Id;
end;

function CurrentGroups: TIdArray;
var
  Index: LongWord;
begin
  EnsureCredentials;
  Result := nil;
  AppendId(Result, Credentials.EffectiveGroupId);
  Index := 0;
  while Index < Credentials.GroupCount do
  begin
    if not ContainsId(Result, Credentials.Groups[Index]) then
      AppendId(Result, Credentials.Groups[Index]);
    Inc(Index);
  end;
end;

function FindById(const Table: TAccountTable; Id: LongWord): PAccount;
var
  Index: Integer;
begin
  for Index := 0 to High(Table) do
    if Table[Index].Id = Id then
      Exit(@Table[Index]);
  Result := nil;
end;

function FindByName(const Table: TAccountTable; const Name: string): PAccount;
var
  Index: Integer;
begin
  for Index := 0 to High(Table) do
    if Table[Index].Name = Name then
      Exit(@Table[Index]);
  Result := nil;
end;

function FindUserName(UserId: LongWord; out Name: string): Boolean;
var
  Entry: PAccount;
begin
  EnsureLoaded;
  Entry := FindById(Users, UserId);
  Result := Entry <> nil;
  if Result then
    Name := Entry^.Name
  else
    Name := '';
end;

function FindGroupName(GroupId: LongWord; out Name: string): Boolean;
var
  Entry: PAccount;
begin
  EnsureLoaded;
  Entry := FindById(Groups, GroupId);
  Result := Entry <> nil;
  if Result then
    Name := Entry^.Name
  else
    Name := '';
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

{ The id of the account named Name in Table, or Name read as a number. }
function FindIdOf(const Table: TAccountTable; const Name: string; out Id: LongWord): Boolean;
var
  Entry: PAccount;
  Number: Int64;
begin
  Id := 0;
  Entry := FindByName(Table, Name);
  if Entry <> nil then
  begin
    Id := Entry^.Id;
    Exit(True);
  end;
  Result := ParseDecimal(Name, Number) and (Number >= 0) and (Number <= High(LongWord));
  if Result then
    Id := LongWord(Number);
end;

function FindUserId(const Name: string; out UserId: LongWord): Boolean;
begin
  EnsureLoaded;
  Result := FindIdOf(Users, Name, UserId);
end;

function FindGroupId(const Name: string; out GroupId: LongWord): Boolean;
begin
  EnsureLoaded;
  Result := FindIdOf(Groups, Name, GroupId);
end;

function PrimaryGroupOf(UserId: LongWord; out GroupId: LongWord): Boolean;
var
  Entry: PAccount;
begin
  EnsureLoaded;
  GroupId := 0;
  Entry := FindById(Users, UserId);
  Result := Entry <> nil;
  if Result then
    GroupId := Entry^.GroupId;
end;

function UserShell(UserId: LongWord): string;
var
  Entry: PAccount;
begin
  EnsureLoaded;
  Entry := FindById(Users, UserId);
  if Entry = nil then
    Exit('/bin/sh');
  Result := Entry^.Shell;
end;

function UserHomeDirectory(UserId: LongWord): string;
var
  Entry: PAccount;
begin
  EnsureLoaded;
  Entry := FindById(Users, UserId);
  if Entry = nil then
    Exit('/');
  Result := Entry^.Home;
end;

function UserFullName(UserId: LongWord): string;
var
  Entry: PAccount;
begin
  EnsureLoaded;
  Entry := FindById(Users, UserId);
  if Entry = nil then
    Exit('');
  Result := Entry^.FullName;
end;

{ True if Name appears in the comma separated Members list. }
function IsMember(const Members, Name: string): Boolean;
var
  Start: Integer;
  Finish: Integer;
begin
  Start := 1;
  while Start <= Length(Members) do
  begin
    Finish := PosEx(',', Members, Start);
    if Finish = 0 then
      Finish := Length(Members) + 1;
    if Copy(Members, Start, Finish - Start) = Name then
      Exit(True);
    Start := Finish + 1;
  end;
  Result := False;
end;

function GroupsOfUser(UserId: LongWord): TIdArray;
var
  Primary: LongWord;
  Name: string;
  Index: Integer;
begin
  EnsureLoaded;
  Result := nil;
  if PrimaryGroupOf(UserId, Primary) then
    AppendId(Result, Primary);
  if not FindUserName(UserId, Name) then
    Exit;
  for Index := 0 to High(Groups) do
  begin
    if (Length(Result) > 0) and (Groups[Index].Id = Primary) then
      Continue;
    if IsMember(Groups[Index].Members, Name) then
      AppendId(Result, Groups[Index].Id);
  end;
end;

procedure RecheckAccountFiles;
begin
  CheckDue := True;
end;

function UserAt(Index: Integer; out UserId: LongWord): Boolean;
begin
  EnsureLoaded;
  UserId := 0;
  Result := (Index >= 0) and (Index < Length(Users));
  if Result then
    UserId := Users[Index].Id;
end;

function GroupAt(Index: Integer; out GroupId: LongWord): Boolean;
begin
  EnsureLoaded;
  GroupId := 0;
  Result := (Index >= 0) and (Index < Length(Groups));
  if Result then
    GroupId := Groups[Index].Id;
end;

function GroupListsMember(GroupId: LongWord; const Name: string): Boolean;
var
  Entry: PAccount;
begin
  EnsureLoaded;
  Entry := FindById(Groups, GroupId);
  Result := (Entry <> nil) and IsMember(Entry^.Members, Name);
end;

end.
