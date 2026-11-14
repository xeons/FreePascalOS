{
  Users and groups, from /etc/passwd and /etc/group.

  The system does not separate users yet: every program runs as root
  (user and group 0). The account files give the numeric owners stored
  in file systems their names, and let chown accept names.

  /etc/passwd lines: name:password:uid:gid:comment:home:shell
  /etc/group lines:  name:password:gid:member,member,...
}
unit Util.Accounts;

{$mode objfpc}
{$pointermath on}

interface

const
  RootId = 0;

{ The running program's user and group (always root for now). }
function CurrentUserId: LongWord;
function CurrentGroupId: LongWord;

{ Returns nil if there is no such account. }
function UserNameOf(UserId: LongWord): PChar;
function GroupNameOf(GroupId: LongWord): PChar;
{ Accept names and decimal numbers. }
function FindUserId(Name: PChar; out UserId: LongWord): Boolean;
function FindGroupId(Name: PChar; out GroupId: LongWord): Boolean;
function PrimaryGroupOf(UserId: LongWord; out GroupId: LongWord): Boolean;
function HomeDirectoryOf(UserId: LongWord): PChar;
{ Number of groups listing UserName as a member, or with it as primary
  group; their ids go to Groups (up to Capacity). }
function GroupsOfUser(UserId: LongWord; Groups: PLongWord; Capacity: Integer): Integer;

implementation

uses
  Runtime.Text,
  Sys.Files,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Input;

type
  TAccount = record
    Name: PChar;
    Id: LongWord;
    GroupId: LongWord;   { users: primary group }
    Home: PChar;         { users }
    Members: PChar;      { groups: comma separated }
  end;
  PAccount = ^TAccount;

var
  Users: PAccount = nil;
  UserCount: Integer = 0;
  Groups: PAccount = nil;
  GroupCount: Integer = 0;
  Loaded: Boolean = False;

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

procedure LoadFile(Path: PChar; IsGroupFile: Boolean; var Table: PAccount; var Count: Integer);
var
  Stream: PInputStream;
  Lines: TLineList;
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
  BeginLineList(Lines);
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
      if FieldCount >= 6 then
        Entry^.Home := Fields[5]
      else
        Entry^.Home := '/';
    end;
    Inc(Count);
  end;
  { The line texts stay in use by the table; only the list goes. }
  FreeMemory(Lines.Items);
end;

procedure EnsureLoaded;
begin
  if Loaded then
    Exit;
  Loaded := True;
  LoadFile('/etc/passwd', False, Users, UserCount);
  LoadFile('/etc/group', True, Groups, GroupCount);
end;

function CurrentUserId: LongWord;
begin
  Result := RootId;
end;

function CurrentGroupId: LongWord;
begin
  Result := RootId;
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

end.
