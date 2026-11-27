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
  The SFTP requests and their answers: open, read, write, close, stat,
  lstat, fstat, setstat, fsetstat, opendir, readdir, mkdir, rmdir,
  remove, rename, realpath, readlink and symlink, and the extensions
  posix-rename@openssh.com (rename over an existing file),
  expand-path@openssh.com ("~/" paths, which scp asks for),
  fsync@openssh.com and limits@openssh.com.

  Everything runs as the user the SSH server started this program as,
  so the file system's own permission checks apply.
}
unit Sftp.Server;

{$mode objfpc}{$H+}

interface

{ Serves requests until the client goes; returns the exit code. }
function RunSftpServer: LongInt;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Ssh.Wire,
  Sftp.Protocol,
  Sftp.Attributes,
  Sftp.Handles,
  Sftp.Packets,
  Sftp.Paths;

const
  MaximumReadLength = 64 * 1024;
  EntriesPerReply = 64;

var
  Handles: TSftpHandleTable;

function StatusFor(Error: LongInt): LongWord;
begin
  case Error of
    ErrorNone: Result := StatusOk;
    ErrorNotFound, ErrorNotDirectory: Result := StatusNoSuchFile;
    ErrorAccessDenied, ErrorNotPermitted, ErrorReadOnly: Result := StatusPermissionDenied;
    ErrorUnsupported, ErrorNotImplemented: Result := StatusUnsupported;
  else
    Result := StatusFailure;
  end;
end;

procedure SendStatus(Id: LongWord; Code: LongWord; const Text: string);
begin
  WritePacket(SshByte(ReplyStatus) + SshUInt32(Id) + SshUInt32(Code) + SshString(Text) + SshString(''));
end;

procedure SendError(Id: LongWord; Error: LongInt);
begin
  if Error = ErrorNone then
    SendStatus(Id, StatusOk, 'Success')
  else
    SendStatus(Id, StatusFor(Error), string(ErrorMessage(Error)));
end;

procedure SendHandle(Id: LongWord; const Handle: string);
begin
  WritePacket(SshByte(ReplyHandle) + SshUInt32(Id) + SshString(Handle));
end;

procedure SendAttributes(Id: LongWord; constref Information: TAbiFileInformation);
begin
  WritePacket(SshByte(ReplyAttributes) + SshUInt32(Id) + EncodeAttributes(Information));
end;

procedure SendSingleName(Id: LongWord; const Name: string);
begin
  WritePacket(SshByte(ReplyName) + SshUInt32(Id) + SshUInt32(1) + SshString(Name) + SshString(Name) +
    EmptyAttributes);
end;

procedure HandleInit(const Packet: string);
begin
  WritePacket(SshByte(PacketVersion) + SshUInt32(SftpVersion) +
    SshString(ExtensionPosixRename) + SshString('1') +
    SshString(ExtensionExpandPath) + SshString('1') +
    SshString(ExtensionFileSync) + SshString('1') +
    SshString(ExtensionLimits) + SshString('1'));
end;

function OpenFlagsFor(Flags: LongWord): LongWord;
begin
  Result := 0;
  if (Flags and OpenFlagRead) <> 0 then
    Result := Result or OpenRead;
  if (Flags and OpenFlagWrite) <> 0 then
    Result := Result or OpenWrite;
  if (Flags and OpenFlagAppend) <> 0 then
    Result := Result or OpenAppend or OpenWrite;
  if (Flags and OpenFlagCreate) <> 0 then
    Result := Result or OpenCreate;
  if (Flags and OpenFlagTruncate) <> 0 then
    Result := Result or OpenTruncate;
  if (Flags and OpenFlagExclusive) <> 0 then
    Result := Result or OpenExclusive;
end;

procedure HandleOpen(Id: LongWord; var Reader: TSshReader);
var
  Path: string;
  Flags: LongWord;
  Attributes: TSftpAttributes;
  Existed: Boolean;
  SystemHandle: Int64;
  Handle: string;
begin
  Path := CanonicalPath(Reader.ReadString);
  Flags := Reader.ReadUInt32;
  Attributes := ReadAttributes(Reader);
  Existed := PathExists(PChar(Path));
  SystemHandle := OpenFile(PChar(Path), OpenFlagsFor(Flags));
  if SystemHandle < 0 then
  begin
    SendError(Id, ErrorCodeOf(SystemHandle));
    Exit;
  end;
  { A new file gets the mode the client asked for. }
  if not Existed and ((Attributes.Flags and AttributePermissions) <> 0) then
    ChangeMode(PChar(Path), Attributes.Permissions and $FFF);
  Handle := Handles.Add(SftpFile, SystemHandle, Path);
  if Handle = '' then
  begin
    CloseFile(SystemHandle);
    SendStatus(Id, StatusFailure, 'too many open files');
    Exit;
  end;
  SendHandle(Id, Handle);
end;

procedure HandleClose(Id: LongWord; var Reader: TSshReader);
begin
  if Handles.Close(Reader.ReadString) then
    SendStatus(Id, StatusOk, 'Success')
  else
    SendStatus(Id, StatusFailure, 'no such handle');
end;

procedure HandleRead(Id: LongWord; var Reader: TSshReader);
var
  Entry: PSftpOpenHandle;
  Offset: QWord;
  Wanted: LongWord;
  Data: string;
  Done: Integer;
  Got: Int64;
begin
  Entry := Handles.Find(Reader.ReadString, SftpFile);
  Offset := Reader.ReadUInt64;
  Wanted := Reader.ReadUInt32;
  if Entry = nil then
  begin
    SendStatus(Id, StatusFailure, 'no such handle');
    Exit;
  end;
  if Wanted > MaximumReadLength then
    Wanted := MaximumReadLength;
  if SeekFile(Entry^.SystemHandle, Int64(Offset), SeekFromStart) < 0 then
  begin
    SendStatus(Id, StatusFailure, 'cannot seek');
    Exit;
  end;
  Data := '';
  SetLength(Data, Wanted);
  Done := 0;
  while Done < Integer(Wanted) do
  begin
    Got := ReadFile(Entry^.SystemHandle, @Data[Done + 1], Integer(Wanted) - Done);
    if Got < 0 then
    begin
      SendError(Id, ErrorCodeOf(Got));
      Exit;
    end;
    if Got = 0 then
      Break;
    Done := Done + Integer(Got);
  end;
  if Done = 0 then
  begin
    SendStatus(Id, StatusEndOfFile, 'End of file');
    Exit;
  end;
  SetLength(Data, Done);
  WritePacket(SshByte(ReplyData) + SshUInt32(Id) + SshString(Data));
end;

procedure HandleWrite(Id: LongWord; var Reader: TSshReader);
var
  Entry: PSftpOpenHandle;
  Offset: QWord;
  Data: string;
begin
  Entry := Handles.Find(Reader.ReadString, SftpFile);
  Offset := Reader.ReadUInt64;
  Data := Reader.ReadString;
  if Entry = nil then
  begin
    SendStatus(Id, StatusFailure, 'no such handle');
    Exit;
  end;
  if SeekFile(Entry^.SystemHandle, Int64(Offset), SeekFromStart) < 0 then
  begin
    SendStatus(Id, StatusFailure, 'cannot seek');
    Exit;
  end;
  if Data = '' then
    SendError(Id, ErrorNone)
  else
    SendError(Id, WriteAll(Entry^.SystemHandle, @Data[1], Length(Data)));
end;

procedure HandlePathStatus(Id: LongWord; var Reader: TSshReader; FollowLinks: Boolean);
var
  Path: string;
  Information: TAbiFileInformation;
  Error: LongInt;
begin
  Path := CanonicalPath(Reader.ReadString);
  if FollowLinks then
    Error := GetFileInformation(PChar(Path), Information)
  else
    Error := GetLinkInformation(PChar(Path), Information);
  if Error = ErrorNone then
    SendAttributes(Id, Information)
  else
    SendError(Id, Error);
end;

procedure HandleHandleStatus(Id: LongWord; var Reader: TSshReader);
var
  Text: string;
  Entry: PSftpOpenHandle;
  Information: TAbiFileInformation;
  Error: LongInt;
begin
  Text := Reader.ReadString;
  Entry := Handles.Find(Text, SftpFile);
  if Entry = nil then
    Entry := Handles.Find(Text, SftpDirectory);
  if Entry = nil then
  begin
    SendStatus(Id, StatusFailure, 'no such handle');
    Exit;
  end;
  Error := GetHandleInformation(Entry^.SystemHandle, Information);
  if Error = ErrorNone then
    SendAttributes(Id, Information)
  else
    SendError(Id, Error);
end;

procedure HandleSetStatus(Id: LongWord; var Reader: TSshReader; ByHandle: Boolean);
var
  Text, Path: string;
  Entry: PSftpOpenHandle;
  Attributes: TSftpAttributes;
begin
  Text := Reader.ReadString;
  Attributes := ReadAttributes(Reader);
  if ByHandle then
  begin
    Entry := Handles.Find(Text, SftpFile);
    if Entry = nil then
      Entry := Handles.Find(Text, SftpDirectory);
    if Entry = nil then
    begin
      SendStatus(Id, StatusFailure, 'no such handle');
      Exit;
    end;
    if (Attributes.Flags and AttributeSize) <> 0 then
    begin
      SendError(Id, SetFileSize(Entry^.SystemHandle, Attributes.Size));
      Exit;
    end;
    Path := Entry^.Path;
  end
  else
    Path := CanonicalPath(Text);
  SendError(Id, ApplyAttributes(Path, Attributes));
end;

procedure HandleOpenDirectory(Id: LongWord; var Reader: TSshReader);
var
  Path: string;
  SystemHandle: Int64;
  Information: TAbiFileInformation;
  Handle: string;
begin
  Path := CanonicalPath(Reader.ReadString);
  SystemHandle := OpenFile(PChar(Path), OpenRead);
  if SystemHandle < 0 then
  begin
    SendError(Id, ErrorCodeOf(SystemHandle));
    Exit;
  end;
  if (GetHandleInformation(SystemHandle, Information) <> ErrorNone) or (Information.Kind <> KindDirectory) then
  begin
    CloseFile(SystemHandle);
    SendError(Id, ErrorNotDirectory);
    Exit;
  end;
  Handle := Handles.Add(SftpDirectory, SystemHandle, Path);
  if Handle = '' then
  begin
    CloseFile(SystemHandle);
    SendStatus(Id, StatusFailure, 'too many open files');
    Exit;
  end;
  SendHandle(Id, Handle);
end;

procedure HandleReadDirectory(Id: LongWord; var Reader: TSshReader);
var
  Entry: PSftpOpenHandle;
  DirectoryEntry: TAbiDirectoryEntry;
  Information: TAbiFileInformation;
  Name, Names: string;
  Count: LongWord;
begin
  Entry := Handles.Find(Reader.ReadString, SftpDirectory);
  if Entry = nil then
  begin
    SendStatus(Id, StatusFailure, 'no such handle');
    Exit;
  end;
  Names := '';
  Count := 0;
  while (Count < EntriesPerReply) and ReadDirectoryEntry(Entry^.SystemHandle, DirectoryEntry) do
  begin
    Name := PChar(@DirectoryEntry.Name[0]);
    if GetLinkInformation(PChar(Entry^.Path + '/' + Name), Information) <> ErrorNone then
    begin
      Information := Default(TAbiFileInformation);
      Information.Kind := DirectoryEntry.Kind;
    end;
    Names := Names + SshString(Name) + SshString(LongName(Name, Information)) + EncodeAttributes(Information);
    Inc(Count);
  end;
  if Count = 0 then
    SendStatus(Id, StatusEndOfFile, 'End of file')
  else
    WritePacket(SshByte(ReplyName) + SshUInt32(Id) + SshUInt32(Count) + Names);
end;

procedure HandleMakeDirectory(Id: LongWord; var Reader: TSshReader);
var
  Path: string;
  Attributes: TSftpAttributes;
  Error: LongInt;
begin
  Path := CanonicalPath(Reader.ReadString);
  Attributes := ReadAttributes(Reader);
  Error := CreateDirectory(PChar(Path));
  if (Error = ErrorNone) and ((Attributes.Flags and AttributePermissions) <> 0) then
    ChangeMode(PChar(Path), Attributes.Permissions and $FFF);
  SendError(Id, Error);
end;

{ remove and rmdir: the kind of node must fit. }
procedure HandleRemove(Id: LongWord; var Reader: TSshReader; Directory: Boolean);
var
  Path: string;
  Information: TAbiFileInformation;
  Error: LongInt;
begin
  Path := CanonicalPath(Reader.ReadString);
  Error := GetLinkInformation(PChar(Path), Information);
  if Error = ErrorNone then
  begin
    if Directory and (Information.Kind <> KindDirectory) then
      Error := ErrorNotDirectory
    else if not Directory and (Information.Kind = KindDirectory) then
      Error := ErrorIsDirectory
    else
      Error := RemovePath(PChar(Path));
  end;
  SendError(Id, Error);
end;

{ SSH_FXP_RENAME does not replace an existing file; posix-rename does. }
procedure Rename(Id: LongWord; const Source, Target: string; Replace: Boolean);
begin
  if not Replace and PathExists(PChar(Target)) then
    SendStatus(Id, StatusFailure, 'the target exists')
  else
    SendError(Id, RenamePath(PChar(Source), PChar(Target)));
end;

procedure HandleRename(Id: LongWord; var Reader: TSshReader; Replace: Boolean);
var
  Source, Target: string;
begin
  Source := CanonicalPath(Reader.ReadString);
  Target := CanonicalPath(Reader.ReadString);
  Rename(Id, Source, Target, Replace);
end;

procedure HandleReadLink(Id: LongWord; var Reader: TSshReader);
var
  Target: string;
  Error: LongInt;
begin
  Error := ReadLinkTarget(CanonicalPath(Reader.ReadString), Target);
  if Error = ErrorNone then
    SendSingleName(Id, Target)
  else
    SendError(Id, Error);
end;

procedure HandleSymbolicLink(Id: LongWord; var Reader: TSshReader);
var
  Target, LinkPath: string;
begin
  { OpenSSH sends the target first and the link second (the reverse of
    the draft), and every client follows it. }
  Target := Reader.ReadString;
  LinkPath := CanonicalPath(Reader.ReadString);
  SendError(Id, CreateSymbolicLink(PChar(Target), PChar(LinkPath)));
end;

procedure HandleExtended(Id: LongWord; var Reader: TSshReader);
var
  Name: string;
  Entry: PSftpOpenHandle;
begin
  Name := Reader.ReadString;
  if Name = ExtensionPosixRename then
    HandleRename(Id, Reader, True)
  else if Name = ExtensionExpandPath then
    SendSingleName(Id, ExpandedPath(Reader.ReadString))
  else if Name = ExtensionFileSync then
  begin
    Entry := Handles.Find(Reader.ReadString, SftpFile);
    if Entry = nil then
      SendStatus(Id, StatusFailure, 'no such handle')
    else
      SendError(Id, SyncFileSystems);
  end
  else if Name = ExtensionLimits then
    WritePacket(SshByte(ReplyExtended) + SshUInt32(Id) + SshUInt64(MaximumSftpPacket - 1024) +
      SshUInt64(MaximumReadLength) + SshUInt64(MaximumReadLength) + SshUInt64(MaximumOpenHandles))
  else
    SendStatus(Id, StatusUnsupported, 'unsupported extension ' + Name);
end;

procedure HandleRequest(const Packet: string);
var
  Reader: TSshReader;
  PacketType: Byte;
  Id: LongWord;
begin
  Reader.Start(Packet);
  PacketType := Reader.ReadByte;
  if PacketType = PacketInit then
  begin
    HandleInit(Packet);
    Exit;
  end;
  Id := Reader.ReadUInt32;
  try
    case PacketType of
      PacketOpen: HandleOpen(Id, Reader);
      PacketClose: HandleClose(Id, Reader);
      PacketRead: HandleRead(Id, Reader);
      PacketWrite: HandleWrite(Id, Reader);
      PacketLinkStatus: HandlePathStatus(Id, Reader, False);
      PacketStatus: HandlePathStatus(Id, Reader, True);
      PacketHandleStatus: HandleHandleStatus(Id, Reader);
      PacketSetStatus: HandleSetStatus(Id, Reader, False);
      PacketHandleSetStatus: HandleSetStatus(Id, Reader, True);
      PacketOpenDirectory: HandleOpenDirectory(Id, Reader);
      PacketReadDirectory: HandleReadDirectory(Id, Reader);
      PacketRemove: HandleRemove(Id, Reader, False);
      PacketMakeDirectory: HandleMakeDirectory(Id, Reader);
      PacketRemoveDirectory: HandleRemove(Id, Reader, True);
      PacketRealPath: SendSingleName(Id, CanonicalPath(Reader.ReadString));
      PacketRename: HandleRename(Id, Reader, False);
      PacketReadLink: HandleReadLink(Id, Reader);
      PacketSymbolicLink: HandleSymbolicLink(Id, Reader);
      PacketExtended: HandleExtended(Id, Reader);
    else
      SendStatus(Id, StatusUnsupported, 'unsupported request');
    end;
  except
    on ESshProtocolError do
      SendStatus(Id, StatusBadMessage, 'malformed request');
  end;
end;

function RunSftpServer: LongInt;
var
  Packet: string;
begin
  Handles := TSftpHandleTable.Create;
  try
    while ReadPacket(Packet) do
    begin
      try
        HandleRequest(Packet);
      except
        on ESshProtocolError do
          { Not even an id to answer to. }
          ;
      end;
    end;
  finally
    Handles.Free;
  end;
  Result := 0;
end;

end.
