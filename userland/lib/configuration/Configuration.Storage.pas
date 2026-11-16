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
  Where a scope's settings are kept: the text of each group, read and
  written whole.

  TSettingsStorage is what a scope (Configuration.Scopes) needs of it.
  On the system it is a folder of files (Configuration.FileStorage); the
  host tests give it a table in memory instead, so the rest of the
  library is tested without a file system.

  The rules every storage keeps:

    - writing a group replaces its text at once: a reader sees the old
      text or the new, never a mixture;
    - Lock and Unlock take turns between writers (other processes too):
      a scope holds the lock while it reads the latest text, changes it
      and writes it, so two programs changing a group at once keep both
      changes;
    - every version of a group's text has an identity, which changes
      whenever the text is replaced, so a scope can tell that what it
      read is out of date by looking at the identity alone.

  Errors are the system's error codes (Abi.SystemCalls): ErrorNotFound
  for a group that has no text.
}
unit Configuration.Storage;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TSettingsVersion = record
    Exists: Boolean;
    { Each write makes a new file (a new node), so the node number alone
      changes with every version; size and time are a further check. }
    NodeNumber: QWord;
    Size: QWord;
    ModificationTime: Int64;
  end;

  TSettingsStorage = class
  public
    { The group's text and its version. }
    function ReadGroup(const Group: string; out Text: string; out Version: TSettingsVersion): LongInt;
      virtual; abstract;
    { The version alone (Exists False, and ErrorNone, if there is no
      text). }
    function ReadVersion(const Group: string; out Version: TSettingsVersion): LongInt; virtual; abstract;
    { Replaces the group's text, all at once. }
    function WriteGroup(const Group, Text: string): LongInt; virtual; abstract;
    { Removes the group (ErrorNone if it had no text). }
    function RemoveGroup(const Group: string): LongInt; virtual; abstract;
    { The groups that have text. }
    function ListGroups(out Groups: TStringArray): LongInt; virtual; abstract;
    { Waits for the writers' lock; held until Unlock. }
    function Lock: LongInt; virtual; abstract;
    procedure Unlock; virtual; abstract;
    { Where the settings are, for messages (a folder). }
    function Location: string; virtual; abstract;
  end;

function SameSettingsVersion(const First, Second: TSettingsVersion): Boolean;

implementation

function SameSettingsVersion(const First, Second: TSettingsVersion): Boolean;
begin
  Result := (First.Exists = Second.Exists) and (First.NodeNumber = Second.NodeNumber) and
    (First.Size = Second.Size) and (First.ModificationTime = Second.ModificationTime);
end;

end.
