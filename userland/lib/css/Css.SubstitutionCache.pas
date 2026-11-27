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
  The values var() declarations gave, remembered: a declaration with
  var() in it is substituted and parsed again for every element it
  applies to, but custom property sets are shared by whole subtrees
  (Css.CustomProperties), so the same declaration meets the same set
  over and over. The answer depends on nothing else but the longhand
  asked for and, for a shorthand's logical longhands, the writing mode
  and direction.

  A fixed table, one entry per slot (a newer answer replaces an older
  one). Each entry holds references to its declaration value and its
  set, so neither address can be reused by another while it is there.
}
unit Css.SubstitutionCache;

{$mode objfpc}
{$H+}

interface

uses
  Css.Values, Css.PropertyIds, Css.Properties, Css.CustomProperties;

type
  TCssSubstitutionKey = record
    Declaration: TCssValue;
    Properties: TCssCustomProperties;
    Id: TCssPropertyId;
    WritingMode: TCssWritingMode;
    RightToLeft: Boolean;
  end;

  TCssSubstitutionCache = class
  private
    type
      TEntry = record
        Key: TCssSubstitutionKey;
        { nil: invalid at computed-value time. }
        Value: TCssValue;
        Used: Boolean;
      end;
    var
      FEntries: array of TEntry;
    function SlotOf(const Key: TCssSubstitutionKey): Integer;
    procedure ReleaseEntry(var Entry: TEntry);
  public
    constructor Create;
    destructor Destroy; override;
    { The remembered value for Key (not a new reference; nil when it was
      invalid); False when there is none. }
    function Find(const Key: TCssSubstitutionKey; out Value: TCssValue): Boolean;
    { Remembers Value (nil: invalid) for Key, taking references. }
    procedure Store(const Key: TCssSubstitutionKey; Value: TCssValue);
    procedure Clear;
  end;

function SubstitutionKey(Declaration: TCssValue; Properties: TCssCustomProperties; Id: TCssPropertyId;
  WritingMode: TCssWritingMode; RightToLeft: Boolean): TCssSubstitutionKey;

implementation

const
  { A power of two. }
  SlotCount = 2048;

function SubstitutionKey(Declaration: TCssValue; Properties: TCssCustomProperties; Id: TCssPropertyId;
  WritingMode: TCssWritingMode; RightToLeft: Boolean): TCssSubstitutionKey;
begin
  Result.Declaration := Declaration;
  Result.Properties := Properties;
  Result.Id := Id;
  Result.WritingMode := WritingMode;
  Result.RightToLeft := RightToLeft;
end;

function SameKey(const A, B: TCssSubstitutionKey): Boolean; inline;
begin
  Result := (A.Declaration = B.Declaration) and (A.Properties = B.Properties) and (A.Id = B.Id) and
    (A.WritingMode = B.WritingMode) and (A.RightToLeft = B.RightToLeft);
end;

constructor TCssSubstitutionCache.Create;
begin
  inherited Create;
  SetLength(FEntries, SlotCount);
end;

destructor TCssSubstitutionCache.Destroy;
begin
  Clear;
  inherited Destroy;
end;

function TCssSubstitutionCache.SlotOf(const Key: TCssSubstitutionKey): Integer;
var
  Hash: PtrUInt;
begin
  Hash := (PtrUInt(Key.Declaration) shr 4) * 2654435761 xor (PtrUInt(Key.Properties) shr 4) * 40503 xor
    PtrUInt(Ord(Key.Id)) * 97 xor PtrUInt(Ord(Key.WritingMode)) * 7 xor PtrUInt(Ord(Key.RightToLeft));
  Result := Integer((Hash xor (Hash shr 16)) and (SlotCount - 1));
end;

procedure TCssSubstitutionCache.ReleaseEntry(var Entry: TEntry);
begin
  if not Entry.Used then
    Exit;
  Entry.Key.Declaration.Release;
  Entry.Key.Properties.Release;
  Entry.Value.Release;
  Entry.Used := False;
end;

function TCssSubstitutionCache.Find(const Key: TCssSubstitutionKey; out Value: TCssValue): Boolean;
var
  Entry: ^TEntry;
begin
  Entry := @FEntries[SlotOf(Key)];
  Result := Entry^.Used and SameKey(Entry^.Key, Key);
  if Result then
    Value := Entry^.Value
  else
    Value := nil;
end;

procedure TCssSubstitutionCache.Store(const Key: TCssSubstitutionKey; Value: TCssValue);
var
  Entry: ^TEntry;
begin
  Entry := @FEntries[SlotOf(Key)];
  ReleaseEntry(Entry^);
  Entry^.Key := Key;
  Key.Declaration.AddRef;
  Key.Properties.AddRef;
  Entry^.Value := Value.AddRef;
  Entry^.Used := True;
end;

procedure TCssSubstitutionCache.Clear;
var
  Index: Integer;
begin
  for Index := 0 to High(FEntries) do
    ReleaseEntry(FEntries[Index]);
end;

end.
