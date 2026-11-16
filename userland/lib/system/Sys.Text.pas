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
  Character classes (ASCII) and a growable buffer of zero terminated
  text, the one ReadLine builds a line in (Sys.Streams). The basic
  PChar routines (TextLength, TextIsEqual, CopyText, number formatting)
  come from Runtime.Text, which this library also contains; numbers in
  text are Util.Numbers'.
}
unit Sys.Text;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.Text;

type
  { A string that grows as text is appended. Text is always terminated. }
  TTextBuilder = record
    Text: PChar;
    Length: PtrUInt;
    Capacity: PtrUInt;
  end;

function IsDigit(Character: Char): Boolean;
function IsSpace(Character: Char): Boolean;
function IsLetter(Character: Char): Boolean;
function IsAlphanumeric(Character: Char): Boolean;
function IsUpperCase(Character: Char): Boolean;
function IsLowerCase(Character: Char): Boolean;
function IsPrintable(Character: Char): Boolean;
function ToUpperCase(Character: Char): Char;
function ToLowerCase(Character: Char): Char;

procedure BeginText(out Builder: TTextBuilder);
procedure AppendText(var Builder: TTextBuilder; Text: PChar);
procedure AppendCharacter(var Builder: TTextBuilder; Character: Char);
procedure AppendBytes(var Builder: TTextBuilder; Bytes: PChar; Count: PtrUInt);
procedure AppendDecimal(var Builder: TTextBuilder; Value: Int64);
{ Gives up ownership of the text (free it with FreeMemory). }
function FinishText(var Builder: TTextBuilder): PChar;
procedure DiscardText(var Builder: TTextBuilder);

implementation

uses
  Runtime.Memory,
  Sys.Memory;

function IsDigit(Character: Char): Boolean;
begin
  Result := (Character >= '0') and (Character <= '9');
end;

function IsSpace(Character: Char): Boolean;
begin
  Result := (Character = ' ') or (Character = #9) or (Character = #10) or
    (Character = #11) or (Character = #12) or (Character = #13);
end;

function IsUpperCase(Character: Char): Boolean;
begin
  Result := (Character >= 'A') and (Character <= 'Z');
end;

function IsLowerCase(Character: Char): Boolean;
begin
  Result := (Character >= 'a') and (Character <= 'z');
end;

function IsLetter(Character: Char): Boolean;
begin
  Result := IsUpperCase(Character) or IsLowerCase(Character);
end;

function IsAlphanumeric(Character: Char): Boolean;
begin
  Result := IsLetter(Character) or IsDigit(Character);
end;

function IsPrintable(Character: Char): Boolean;
begin
  Result := (Character >= ' ') and (Character <> #127);
end;

function ToUpperCase(Character: Char): Char;
begin
  if IsLowerCase(Character) then
    Result := Char(Ord(Character) - 32)
  else
    Result := Character;
end;

function ToLowerCase(Character: Char): Char;
begin
  if IsUpperCase(Character) then
    Result := Char(Ord(Character) + 32)
  else
    Result := Character;
end;

{ --- Builder --------------------------------------------------------- }

procedure BeginText(out Builder: TTextBuilder);
begin
  Builder.Capacity := 64;
  Builder.Text := PChar(AllocateMemory(Builder.Capacity));
  Builder.Length := 0;
  if Builder.Text <> nil then
    Builder.Text[0] := #0
  else
    Builder.Capacity := 0;
end;

procedure EnsureCapacity(var Builder: TTextBuilder; Needed: PtrUInt);
var
  NewCapacity: PtrUInt;
begin
  if Needed < Builder.Capacity then
    Exit;
  NewCapacity := Builder.Capacity * 2;
  if NewCapacity < 64 then
    NewCapacity := 64;
  while NewCapacity <= Needed do
    NewCapacity := NewCapacity * 2;
  Builder.Text := PChar(ReallocateMemory(Builder.Text, NewCapacity));
  if Builder.Text = nil then
  begin
    Builder.Capacity := 0;
    Builder.Length := 0;
    Exit;
  end;
  Builder.Capacity := NewCapacity;
end;

procedure AppendBytes(var Builder: TTextBuilder; Bytes: PChar; Count: PtrUInt);
begin
  EnsureCapacity(Builder, Builder.Length + Count + 1);
  if Builder.Text = nil then
    Exit;
  CopyMemory(Builder.Text + Builder.Length, Bytes, Count);
  Builder.Length := Builder.Length + Count;
  Builder.Text[Builder.Length] := #0;
end;

procedure AppendText(var Builder: TTextBuilder; Text: PChar);
begin
  if Text <> nil then
    AppendBytes(Builder, Text, TextLength(Text));
end;

procedure AppendCharacter(var Builder: TTextBuilder; Character: Char);
begin
  AppendBytes(Builder, @Character, 1);
end;

procedure AppendDecimal(var Builder: TTextBuilder; Value: Int64);
var
  NumberText: TNumberText;
begin
  AppendText(Builder, FormatSignedDecimal(Value, NumberText));
end;

function FinishText(var Builder: TTextBuilder): PChar;
begin
  Result := Builder.Text;
  Builder.Text := nil;
  Builder.Length := 0;
  Builder.Capacity := 0;
end;

procedure DiscardText(var Builder: TTextBuilder);
begin
  FreeMemory(Builder.Text);
  Builder.Text := nil;
  Builder.Length := 0;
  Builder.Capacity := 0;
end;

end.
