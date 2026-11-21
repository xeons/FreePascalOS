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
  Who may do what with files.

  The VFS asks two questions through hooks that the process layer
  installs (see Processes.Security), so that it knows nothing about
  processes itself:

    MayAccess          may the caller read, write or execute/search a
                       node with this owner, group and mode?
    CreationAttributes which owner, group and permission mask should a
                       node the caller creates get?

  Without hooks (early startup, kernel threads) everything is allowed and
  new nodes keep the driver's defaults.

  Formats without owners (FAT, exFAT) get theirs from the mount options
  (FileSystem.OwnerMapping): MapOwnerlessNode gives a node the owner,
  group and mode those say, and FilterOwnerlessChanges lets chown and
  chgrp through only to the owner and group the node already shows.
}
unit FileSystem.Security;

{$mode objfpc}

interface

uses
  FileSystem.Types;

const
  AccessExecute = $01;   { search, for directories }
  AccessWrite = $02;
  AccessRead = $04;

  DefaultFileMode = $1B6;       { rw-rw-rw-, before the mask }
  DefaultDirectoryMode = $1FF;  { rwxrwxrwx, before the mask }
  SymbolicLinkMode = $1FF;      { always rwxrwxrwx }

type
  TAccessCheck = function(const Information: TNodeInformation; Access: LongWord): Boolean;
  { Returns False when created nodes should keep the driver's defaults. }
  TCreationAttributes = function(out OwnerId, GroupId, Mask: LongWord): Boolean;
  { True if the caller is the user OwnerId or may act for anyone. }
  TOwnerCheck = function(OwnerId: LongWord): Boolean;

const
  { The sticky bit: in such a directory only the owner of a name (or of
    the directory) may remove or rename it, as in /tmp. }
  StickyMode = $200;

procedure SetFileSecurityHooks(AccessCheck: TAccessCheck; CreationAttributes: TCreationAttributes;
  OwnerCheck: TOwnerCheck);
{ True if the caller may remove or rename Node in Directory as far as
  the sticky bit goes (write access to Directory is checked apart). }
function MayRemoveFromDirectory(Directory, Node: PNode): Boolean;

function MayAccess(const Information: TNodeInformation; Access: LongWord): Boolean;

{ Gives a node just created by the caller its owner, group and mode
  (DefaultMode, with the caller's mask removed if UseMask). Formats
  without owners keep their own. }
procedure ApplyCreationAttributes(Node: PNode; DefaultMode: LongWord; UseMask: Boolean);

{ On a volume whose format has no owners: gives Node the owner, group
  and mode of the volume's mount options. FromDriver: the driver has
  just described the node (its mode shows the read-only attribute). }
procedure MapOwnerlessNode(Node: PNode; FromDriver: Boolean);

{ Changes for a node on a volume without owners: an owner or group the
  node already shows is dropped (nothing to store), another one is
  StatusUnsupported. Other volumes' changes pass unchanged. }
function FilterOwnerlessChanges(Node: PNode; const Changes: TAttributeChanges;
  out Filtered: TAttributeChanges): TFileSystemStatus;

implementation

uses
  FileSystem.OwnerMapping;

var
  AccessHook: TAccessCheck = nil;
  CreationHook: TCreationAttributes = nil;
  OwnerHook: TOwnerCheck = nil;

procedure SetFileSecurityHooks(AccessCheck: TAccessCheck; CreationAttributes: TCreationAttributes;
  OwnerCheck: TOwnerCheck);
begin
  AccessHook := AccessCheck;
  CreationHook := CreationAttributes;
  OwnerHook := OwnerCheck;
end;

function MayRemoveFromDirectory(Directory, Node: PNode): Boolean;
begin
  if not Assigned(OwnerHook) or ((Directory^.Information.Mode and StickyMode) = 0) then
    Exit(True);
  Result := OwnerHook(Node^.Information.OwnerId) or OwnerHook(Directory^.Information.OwnerId);
end;

function MayAccess(const Information: TNodeInformation; Access: LongWord): Boolean;
begin
  if not Assigned(AccessHook) then
    Exit(True);
  Result := AccessHook(Information, Access);
end;

procedure ApplyCreationAttributes(Node: PNode; DefaultMode: LongWord; UseMask: Boolean);
var
  OwnerId: LongWord;
  GroupId: LongWord;
  Mask: LongWord;
  Changes: TAttributeChanges;
begin
  if not Assigned(CreationHook) or not Assigned(Node^.Volume^.Driver^.SetAttributes) then
    Exit;
  if not CreationHook(OwnerId, GroupId, Mask) then
    Exit;
  if Node^.Volume^.Driver^.HasNoOwners then
  begin
    { Only the read-only attribute can be stored: a mode without write
      permission sets it. }
    Changes.Fields := AttributeChangeMode;
    Changes.Mode := DefaultMode;
    if UseMask then
      Changes.Mode := DefaultMode and not Mask;
    Changes.OwnerId := 0;
    Changes.GroupId := 0;
    Changes.ModificationTime := 0;
    Changes.AccessTime := 0;
    if Node^.Volume^.Driver^.SetAttributes(Node, Changes) = StatusSuccess then
      MapOwnerlessNode(Node, True);
    Exit;
  end;
  Changes.Fields := AttributeChangeMode or AttributeChangeOwner or AttributeChangeGroup;
  Changes.Mode := DefaultMode;
  if UseMask then
    Changes.Mode := DefaultMode and not Mask;
  Changes.OwnerId := OwnerId;
  Changes.GroupId := GroupId;
  Changes.ModificationTime := 0;
  Changes.AccessTime := 0;
  if Node^.Volume^.Driver^.SetAttributes(Node, Changes) <> StatusSuccess then
  begin
    { FAT and exFAT have no owners: set the mode alone. }
    Changes.Fields := AttributeChangeMode;
    Node^.Volume^.Driver^.SetAttributes(Node, Changes);
  end;
end;

procedure MapOwnerlessNode(Node: PNode; FromDriver: Boolean);
var
  Volume: PVolume;
  IsDirectory: Boolean;
begin
  Volume := Node^.Volume;
  if not Volume^.Driver^.HasNoOwners then
    Exit;
  IsDirectory := Node^.Information.Kind = NodeKindDirectory;
  if FromDriver then
    Node^.HasReadOnlyAttribute := ModeMeansReadOnly(Node^.Information.Mode);
  Node^.Information.OwnerId := Volume^.Options.OwnerId;
  Node^.Information.GroupId := Volume^.Options.GroupId;
  Node^.Information.Mode := OwnerlessMode(IsDirectory, Node^.HasReadOnlyAttribute, Volume^.Options);
end;

function FilterOwnerlessChanges(Node: PNode; const Changes: TAttributeChanges;
  out Filtered: TAttributeChanges): TFileSystemStatus;
begin
  Filtered := Changes;
  Result := StatusSuccess;
  if not Node^.Volume^.Driver^.HasNoOwners then
    Exit;
  if (Changes.Fields and AttributeChangeOwner) <> 0 then
  begin
    if Changes.OwnerId <> Node^.Information.OwnerId then
      Exit(StatusUnsupported);
    Filtered.Fields := Filtered.Fields and not AttributeChangeOwner;
  end;
  if (Changes.Fields and AttributeChangeGroup) <> 0 then
  begin
    if Changes.GroupId <> Node^.Information.GroupId then
      Exit(StatusUnsupported);
    Filtered.Fields := Filtered.Fields and not AttributeChangeGroup;
  end;
end;

end.
