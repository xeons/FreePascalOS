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
  The numbers of an ICC profile: everything is big-endian; s15Fixed16
  numbers are 32-bit signed values over 65536; signatures are four
  ASCII characters read as a 32-bit number. The readers check nothing:
  their callers check that what they read lies inside the profile.
}
unit Image.ColorProfiles.Numbers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

function ReadProfileLong(const Profile: TBytes; Offset: PtrInt): LongWord; inline;
function ReadProfileWord(const Profile: TBytes; Offset: PtrInt): Word; inline;
{ An s15Fixed16Number. }
function ReadProfileFixed(const Profile: TBytes; Offset: PtrInt): Double;
{ A signature written as text ('curv', 'RGB ', 'XYZ '...). }
function SignatureOf(const Text: string): LongWord;
{ A signature as text, for messages. }
function SignatureText(Signature: LongWord): string;

implementation

function ReadProfileLong(const Profile: TBytes; Offset: PtrInt): LongWord;
begin
  Result := (LongWord(Profile[Offset]) shl 24) or (LongWord(Profile[Offset + 1]) shl 16) or
    (LongWord(Profile[Offset + 2]) shl 8) or Profile[Offset + 3];
end;

function ReadProfileWord(const Profile: TBytes; Offset: PtrInt): Word;
begin
  Result := (Word(Profile[Offset]) shl 8) or Profile[Offset + 1];
end;

function ReadProfileFixed(const Profile: TBytes; Offset: PtrInt): Double;
begin
  Result := LongInt(ReadProfileLong(Profile, Offset)) / 65536;
end;

function SignatureOf(const Text: string): LongWord;
var
  Index: LongInt;
  Character: Byte;
begin
  Result := 0;
  for Index := 1 to 4 do
  begin
    if Index <= Length(Text) then
      Character := Ord(Text[Index])
    else
      Character := Ord(' ');
    Result := (Result shl 8) or Character;
  end;
end;

function SignatureText(Signature: LongWord): string;
var
  Index: LongInt;
  Character: Byte;
begin
  Result := '';
  for Index := 3 downto 0 do
  begin
    Character := (Signature shr (8 * Index)) and $FF;
    if (Character >= 32) and (Character < 127) then
      Result := Result + Chr(Character)
    else
      Result := Result + '?';
  end;
end;

end.
