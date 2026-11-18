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
  The kernel command line: the words of an options file
  (\FreePascalOS\options.txt on the boot volume, or FreePascalOS/options.txt
  on the network boot server), with line breaks and tabs turned into
  spaces.

  A network boot puts "netboot=<base URL>" first, so the kernel and user
  mode know where the system came from; any other netboot= word is
  dropped.
}
unit Loader.Options;

{$mode objfpc}

interface

uses
  Boot.Information,
  Loader.FileLoading;

procedure SetCommandLineFromFile(var BootInformation: TBootInformation;
  const OptionsFile: TLoadedFile);

{ Copies the value of the first Name=value word of CommandLine into
  Value. False if there is none. }
function FindOptionValue(CommandLine: PChar; Name: PChar; Value: PChar;
  ValueCapacity: PtrUInt): Boolean;

{ Rewrites the command line as "netboot=BaseUrl" and its other words. }
procedure PutNetworkBootFirst(var BootInformation: TBootInformation; BaseUrl: PChar);

implementation

uses
  Runtime.Text;

const
  NetworkBootOptionName = 'netboot';

procedure SetCommandLineFromFile(var BootInformation: TBootInformation;
  const OptionsFile: TLoadedFile);
var
  SourceBytes: PChar;
  Index: QWord;
  Length: QWord;
  Character: Char;
begin
  SourceBytes := PChar(OptionsFile.Contents);
  Length := OptionsFile.SizeInBytes;
  if Length > CommandLineCapacity - 1 then
    Length := CommandLineCapacity - 1;

  Index := 0;
  while Index < Length do
  begin
    Character := SourceBytes[Index];
    if (Character = #10) or (Character = #13) or (Character = #9) or (Character = #0) then
      Character := ' ';
    BootInformation.CommandLine[Index] := Character;
    Inc(Index);
  end;
  BootInformation.CommandLine[Length] := #0;
end;

{ True if the word at Word is Name=... ; Value then points after '='. }
function WordHasName(Word: PChar; Name: PChar; out Value: PChar): Boolean;
begin
  Value := nil;
  while (Name^ <> #0) and (Word^ = Name^) do
  begin
    Inc(Word);
    Inc(Name);
  end;
  Result := (Name^ = #0) and (Word^ = '=');
  if Result then
    Value := Word + 1;
end;

function FindOptionValue(CommandLine: PChar; Name: PChar; Value: PChar;
  ValueCapacity: PtrUInt): Boolean;
var
  Position: PChar;
  Found: PChar;
  Length: PtrUInt;
begin
  Position := CommandLine;
  while Position^ <> #0 do
  begin
    while Position^ = ' ' do
      Inc(Position);
    if Position^ = #0 then
      Break;
    if WordHasName(Position, Name, Found) then
    begin
      Length := 0;
      while (Found[Length] <> #0) and (Found[Length] <> ' ') and (Length + 1 < ValueCapacity) do
      begin
        Value[Length] := Found[Length];
        Inc(Length);
      end;
      Value[Length] := #0;
      Exit(True);
    end;
    while (Position^ <> #0) and (Position^ <> ' ') do
      Inc(Position);
  end;
  Result := False;
end;

procedure AppendCharacter(var Line: array of Char; var Length: PtrUInt; Character: Char);
begin
  if Length + 1 < PtrUInt(High(Line) + 1) then
  begin
    Line[Length] := Character;
    Inc(Length);
  end;
end;

procedure AppendText(var Line: array of Char; var Length: PtrUInt; Text: PChar);
begin
  while Text^ <> #0 do
  begin
    AppendCharacter(Line, Length, Text^);
    Inc(Text);
  end;
end;

procedure PutNetworkBootFirst(var BootInformation: TBootInformation; BaseUrl: PChar);
var
  Line: array[0..CommandLineCapacity - 1] of Char;
  Length: PtrUInt;
  Position: PChar;
  Ignored: PChar;
begin
  Length := 0;
  AppendText(Line, Length, NetworkBootOptionName + '=');
  AppendText(Line, Length, BaseUrl);

  Position := @BootInformation.CommandLine[0];
  while Position^ <> #0 do
  begin
    while Position^ = ' ' do
      Inc(Position);
    if Position^ = #0 then
      Break;
    if WordHasName(Position, NetworkBootOptionName, Ignored) then
    begin
      while (Position^ <> #0) and (Position^ <> ' ') do
        Inc(Position);
      Continue;
    end;
    AppendCharacter(Line, Length, ' ');
    while (Position^ <> #0) and (Position^ <> ' ') do
    begin
      AppendCharacter(Line, Length, Position^);
      Inc(Position);
    end;
  end;
  Line[Length] := #0;
  CopyText(@BootInformation.CommandLine[0], @Line[0], CommandLineCapacity);
end;

end.
