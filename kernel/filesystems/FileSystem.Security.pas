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

procedure SetFileSecurityHooks(AccessCheck: TAccessCheck; CreationAttributes: TCreationAttributes);

function MayAccess(const Information: TNodeInformation; Access: LongWord): Boolean;

{ Gives a node just created by the caller its owner, group and mode
  (DefaultMode, with the caller's mask removed if UseMask). Formats
  without owners keep their own. }
procedure ApplyCreationAttributes(Node: PNode; DefaultMode: LongWord; UseMask: Boolean);

implementation

var
  AccessHook: TAccessCheck = nil;
  CreationHook: TCreationAttributes = nil;

procedure SetFileSecurityHooks(AccessCheck: TAccessCheck; CreationAttributes: TCreationAttributes);
begin
  AccessHook := AccessCheck;
  CreationHook := CreationAttributes;
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

end.
