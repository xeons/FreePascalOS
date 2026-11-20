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
  The list of active formatting elements: formatting elements and
  markers, each element with the tag token it was made for (to make it
  again when formatting is reconstructed or the adoption agency clones
  it).
}
unit Web.Html.FormattingList;

{$mode objfpc}
{$H+}

interface

uses
  Web.Atoms,
  Web.Dom,
  Web.Html.Tokens;

type
  TFormattingEntry = record
    { nil for a marker. }
    Element: TElement;
    TagName: TAtom;
    Attributes: TTokenAttributeArray;
  end;

  TFormattingList = class
  private
    FEntries: array of TFormattingEntry;
    FCount: Integer;
    function GetEntry(Index: Integer): TFormattingEntry; inline;
  public
    procedure PushMarker;
    { Pushes an element (with the Noah's Ark clause: at most three equal
      entries after the last marker). }
    procedure PushElement(Element: TElement; const Token: TToken);
    procedure InsertAt(Index: Integer; const Entry: TFormattingEntry);
    procedure RemoveAt(Index: Integer);
    procedure Remove(Element: TElement);
    function IndexOf(Element: TElement): Integer;
    function Contains(Element: TElement): Boolean; inline;
    procedure ReplaceElement(Index: Integer; Element: TElement);
    { Removes entries up to and including the last marker. }
    procedure ClearToLastMarker;
    { The last element named Name after the last marker, or -1. }
    function LastIndexAfterMarker(Name: TAtom): Integer;
    function IsMarker(Index: Integer): Boolean; inline;
    procedure Clear;
    property Count: Integer read FCount;
    property Entries[Index: Integer]: TFormattingEntry read GetEntry; default;
  end;

implementation

function TFormattingList.GetEntry(Index: Integer): TFormattingEntry;
begin
  Result := FEntries[Index];
end;

procedure TFormattingList.InsertAt(Index: Integer; const Entry: TFormattingEntry);
var
  Position: Integer;
begin
  if FCount >= Length(FEntries) then
    SetLength(FEntries, FCount * 2 + 8);
  Position := FCount;
  while Position > Index do
  begin
    FEntries[Position] := FEntries[Position - 1];
    Dec(Position);
  end;
  FEntries[Index] := Entry;
  Inc(FCount);
end;

procedure TFormattingList.PushMarker;
var
  Entry: TFormattingEntry;
begin
  Entry.Element := nil;
  Entry.TagName := AtomNone;
  Entry.Attributes := nil;
  InsertAt(FCount, Entry);
end;

function SameAttributes(const First, Second: TTokenAttributeArray): Boolean;
var
  Index, Other: Integer;
  Found: Boolean;
begin
  if Length(First) <> Length(Second) then
    Exit(False);
  for Index := 0 to High(First) do
  begin
    Found := False;
    for Other := 0 to High(Second) do
      if (Second[Other].LocalName = First[Index].LocalName) and
        (Second[Other].NamespaceId = First[Index].NamespaceId) and (Second[Other].Value = First[Index].Value) then
      begin
        Found := True;
        Break;
      end;
    if not Found then
      Exit(False);
  end;
  Result := True;
end;

procedure TFormattingList.PushElement(Element: TElement; const Token: TToken);
var
  Entry: TFormattingEntry;
  Index, Matches, Earliest: Integer;
begin
  Entry.Element := Element;
  Entry.TagName := Token.TagName;
  Entry.Attributes := CopyTokenAttributes(Token);
  Matches := 0;
  Earliest := -1;
  Index := FCount - 1;
  while (Index >= 0) and (FEntries[Index].Element <> nil) do
  begin
    if (FEntries[Index].TagName = Entry.TagName) and
      (FEntries[Index].Element.NamespaceId = Element.NamespaceId) and
      SameAttributes(FEntries[Index].Attributes, Entry.Attributes) then
    begin
      Inc(Matches);
      Earliest := Index;
    end;
    Dec(Index);
  end;
  if Matches >= 3 then
    RemoveAt(Earliest);
  InsertAt(FCount, Entry);
end;

procedure TFormattingList.RemoveAt(Index: Integer);
var
  Position: Integer;
begin
  for Position := Index + 1 to FCount - 1 do
    FEntries[Position - 1] := FEntries[Position];
  Dec(FCount);
  FEntries[FCount].Element := nil;
  FEntries[FCount].Attributes := nil;
end;

procedure TFormattingList.Remove(Element: TElement);
var
  Index: Integer;
begin
  Index := IndexOf(Element);
  if Index >= 0 then
    RemoveAt(Index);
end;

function TFormattingList.IndexOf(Element: TElement): Integer;
begin
  Result := FCount - 1;
  while (Result >= 0) and ((FEntries[Result].Element <> Element) or (Element = nil)) do
    Dec(Result);
end;

function TFormattingList.Contains(Element: TElement): Boolean;
begin
  Result := IndexOf(Element) >= 0;
end;

procedure TFormattingList.ReplaceElement(Index: Integer; Element: TElement);
begin
  FEntries[Index].Element := Element;
end;

procedure TFormattingList.ClearToLastMarker;
var
  WasMarker: Boolean;
begin
  while FCount > 0 do
  begin
    WasMarker := FEntries[FCount - 1].Element = nil;
    RemoveAt(FCount - 1);
    if WasMarker then
      Exit;
  end;
end;

function TFormattingList.LastIndexAfterMarker(Name: TAtom): Integer;
begin
  Result := FCount - 1;
  while Result >= 0 do
  begin
    if FEntries[Result].Element = nil then
      Exit(-1);
    if FEntries[Result].TagName = Name then
      Exit;
    Dec(Result);
  end;
end;

function TFormattingList.IsMarker(Index: Integer): Boolean;
begin
  Result := FEntries[Index].Element = nil;
end;

procedure TFormattingList.Clear;
begin
  while FCount > 0 do
    RemoveAt(FCount - 1);
end;

end.
