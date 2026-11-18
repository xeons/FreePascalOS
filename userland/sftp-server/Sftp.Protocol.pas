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
  The numbers of SFTP version 3 (draft-ietf-secsh-filexfer-02, what
  OpenSSH speaks): packet types, open flags, attribute flags and status
  codes.
}
unit Sftp.Protocol;

{$mode objfpc}{$H+}

interface

const
  SftpVersion = 3;

  PacketInit = 1;
  PacketVersion = 2;
  PacketOpen = 3;
  PacketClose = 4;
  PacketRead = 5;
  PacketWrite = 6;
  PacketLinkStatus = 7;
  PacketHandleStatus = 8;
  PacketSetStatus = 9;
  PacketHandleSetStatus = 10;
  PacketOpenDirectory = 11;
  PacketReadDirectory = 12;
  PacketRemove = 13;
  PacketMakeDirectory = 14;
  PacketRemoveDirectory = 15;
  PacketRealPath = 16;
  PacketStatus = 17;
  PacketRename = 18;
  PacketReadLink = 19;
  PacketSymbolicLink = 20;
  PacketExtended = 200;

  ReplyStatus = 101;
  ReplyHandle = 102;
  ReplyData = 103;
  ReplyName = 104;
  ReplyAttributes = 105;
  ReplyExtended = 201;

  OpenFlagRead = $01;
  OpenFlagWrite = $02;
  OpenFlagAppend = $04;
  OpenFlagCreate = $08;
  OpenFlagTruncate = $10;
  OpenFlagExclusive = $20;

  AttributeSize = $00000001;
  AttributeOwners = $00000002;
  AttributePermissions = $00000004;
  AttributeTimes = $00000008;
  AttributeExtended = $80000000;

  StatusOk = 0;
  StatusEndOfFile = 1;
  StatusNoSuchFile = 2;
  StatusPermissionDenied = 3;
  StatusFailure = 4;
  StatusBadMessage = 5;
  StatusUnsupported = 8;

  { The file type bits of a POSIX mode, which clients look at. }
  ModeTypeDirectory = $4000;
  ModeTypeRegular = $8000;
  ModeTypeSymbolicLink = $A000;
  ModeTypeFifo = $1000;
  ModeTypeCharacterDevice = $2000;
  ModeTypeBlockDevice = $6000;

  ExtensionPosixRename = 'posix-rename@openssh.com';
  ExtensionExpandPath = 'expand-path@openssh.com';
  ExtensionFileSync = 'fsync@openssh.com';
  ExtensionLimits = 'limits@openssh.com';

implementation

end.
