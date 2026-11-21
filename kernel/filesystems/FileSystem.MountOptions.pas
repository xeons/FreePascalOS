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
  Mount options: what "mount -o" and /etc/fstab say about a volume.

  The text is a comma separated list, as on Unix:

    ro, rw            read-only (or writable, the default where the
                      driver and the device allow it)
    noexec, exec      programs on the volume may not (may) be started
    nosuid, suid      set-user-ID and set-group-ID bits are (not) ignored
                      when a program on the volume starts
    discard, nodiscard  tell the disk which blocks the file system freed
                      (where the driver and the disk support it)
    uid=N, gid=N      the owner and group of every file, on formats
                      without owners (FAT, exFAT)
    umask=OCTAL       the permissions taken away from files and folders
                      there (fmask and dmask both)
    fmask=OCTAL       the same, for files only
    dmask=OCTAL       the same, for folders only
    size=N[k|m|g|%]   the most a memory volume (tmpfs) holds: bytes,
                      KiB, MiB, GiB or a share of the RAM
    mode=OCTAL        the permissions of a memory volume's root folder
    defaults, atime, noatime, relatime   accepted and ignored

  Without owner options files on FAT and exFAT belong to root and get
  rw-r--r--, folders rwxr-xr-x; a file with the read-only attribute
  loses its write permissions either way (FileSystem.OwnerMapping).

  Plain Pascal (no kernel units), so the host tests build it too.
}
unit FileSystem.MountOptions;

{$mode objfpc}

interface

const
  { rw-r--r-- for files and rwxr-xr-x for folders. }
  DefaultFileMask = $5B;       { 0133 }
  DefaultDirectoryMask = $12;  { 0022 }
  { A memory volume's root: rwxrwxrwt, like /tmp. }
  DefaultMemoryRootMode = $3FF;
  { A memory volume takes at most half the RAM unless told otherwise. }
  DefaultMemorySizePercent = 50;

  MountOptionsTextCapacity = 256;

type
  TMountOptions = record
    ReadOnly: Boolean;
    NoExecute: Boolean;
    NoSetId: Boolean;
    Discard: Boolean;
    OwnerId: LongWord;
    GroupId: LongWord;
    FileMask: LongWord;
    DirectoryMask: LongWord;
    { size=: in bytes, or (SizePercent <> 0) a share of the RAM. }
    SizeLimitBytes: QWord;
    SizePercent: LongWord;
    RootMode: LongWord;
  end;

{ The options of a volume mounted without any. }
procedure SetDefaultMountOptions(out Options: TMountOptions);

{ Applies the comma separated options of Text on top of Options. False
  for an option that is not known or has a wrong value; ErrorPosition
  is then where it starts in Text (counted from 0). }
function ParseMountOptions(Text: PChar; var Options: TMountOptions; out ErrorPosition: Integer): Boolean;

{ Writes Options as text ("rw,noexec,uid=1000,..."), the way mount
  lists them; OwnerOptions adds uid, gid, fmask and dmask, SizeOptions
  size and mode. }
procedure FormatMountOptions(const Options: TMountOptions; OwnerOptions, SizeOptions: Boolean;
  Text: PChar; Capacity: Integer);

implementation

procedure SetDefaultMountOptions(out Options: TMountOptions);
begin
  Options.ReadOnly := False;
  Options.NoExecute := False;
  Options.NoSetId := False;
  Options.Discard := False;
  Options.OwnerId := 0;
  Options.GroupId := 0;
  Options.FileMask := DefaultFileMask;
  Options.DirectoryMask := DefaultDirectoryMask;
  Options.SizeLimitBytes := 0;
  Options.SizePercent := DefaultMemorySizePercent;
  Options.RootMode := DefaultMemoryRootMode;
end;

{ --- Reading --------------------------------------------------------- }

type
  { One option of the list: its name and (after '=') its value. }
  TOptionText = record
    Name: array[0..31] of Char;
    Value: array[0..31] of Char;
    HasValue: Boolean;
    TooLong: Boolean;
  end;

function SameText(A, B: PChar): Boolean;
begin
  while (A^ <> #0) and (A^ = B^) do
  begin
    Inc(A);
    Inc(B);
  end;
  Result := A^ = B^;
end;

{ Splits off the option starting at Text[Position]; Position moves past
  it and its comma. }
procedure TakeOption(Text: PChar; var Position: Integer; out Option: TOptionText);
var
  Length: Integer;
begin
  Option.HasValue := False;
  Option.TooLong := False;
  Length := 0;
  while (Text[Position] <> #0) and (Text[Position] <> ',') and (Text[Position] <> '=') do
  begin
    if Length < High(Option.Name) then
    begin
      Option.Name[Length] := Text[Position];
      Inc(Length);
    end
    else
      Option.TooLong := True;
    Inc(Position);
  end;
  Option.Name[Length] := #0;
  Length := 0;
  if Text[Position] = '=' then
  begin
    Option.HasValue := True;
    Inc(Position);
    while (Text[Position] <> #0) and (Text[Position] <> ',') do
    begin
      if Length < High(Option.Value) then
      begin
        Option.Value[Length] := Text[Position];
        Inc(Length);
      end
      else
        Option.TooLong := True;
      Inc(Position);
    end;
  end;
  Option.Value[Length] := #0;
  if Text[Position] = ',' then
    Inc(Position);
end;

function ParseUnsigned(Text: PChar; Base: LongWord; Limit: QWord; out Value: QWord): Boolean;
var
  Digit: LongWord;
begin
  Value := 0;
  if Text^ = #0 then
    Exit(False);
  while Text^ <> #0 do
  begin
    if (Text^ < '0') or (Text^ > '9') then
      Exit(False);
    Digit := Ord(Text^) - Ord('0');
    if Digit >= Base then
      Exit(False);
    if Value > (Limit - Digit) div Base then
      Exit(False);
    Value := Value * Base + Digit;
    Inc(Text);
  end;
  Result := True;
end;

function ParseIdentity(Text: PChar; out Id: LongWord): Boolean;
var
  Value: QWord;
begin
  Id := 0;
  Result := ParseUnsigned(Text, 10, $FFFFFFFE, Value);
  if Result then
    Id := LongWord(Value);
end;

function ParseMode(Text: PChar; Limit: LongWord; out Mode: LongWord): Boolean;
var
  Value: QWord;
begin
  Mode := 0;
  Result := ParseUnsigned(Text, 8, Limit, Value);
  if Result then
    Mode := LongWord(Value);
end;

{ size=N with an optional k, m, g (powers of 1024) or % at the end. }
function ParseSize(Text: PChar; var Options: TMountOptions): Boolean;
var
  Digits: array[0..31] of Char;
  Length: Integer;
  Value: QWord;
  Shift: Integer;
begin
  Length := 0;
  while (Text[Length] <> #0) and (Length < High(Digits)) do
  begin
    Digits[Length] := Text[Length];
    Inc(Length);
  end;
  if Length = 0 then
    Exit(False);
  Shift := 0;
  case Digits[Length - 1] of
    'k', 'K': Shift := 10;
    'm', 'M': Shift := 20;
    'g', 'G': Shift := 30;
    '%': Shift := -1;
  end;
  if Shift <> 0 then
    Dec(Length);
  Digits[Length] := #0;
  if not ParseUnsigned(@Digits[0], 10, QWord(1) shl 40, Value) then
    Exit(False);
  if Shift = -1 then
  begin
    if (Value = 0) or (Value > 100) then
      Exit(False);
    Options.SizePercent := LongWord(Value);
    Options.SizeLimitBytes := 0;
    Exit(True);
  end;
  Value := Value shl Shift;
  if Value = 0 then
    Exit(False);
  Options.SizeLimitBytes := Value;
  Options.SizePercent := 0;
  Result := True;
end;

function ApplyFlagOption(Name: PChar; var Options: TMountOptions): Boolean;
begin
  Result := True;
  if SameText(Name, 'ro') then
    Options.ReadOnly := True
  else if SameText(Name, 'rw') then
    Options.ReadOnly := False
  else if SameText(Name, 'noexec') then
    Options.NoExecute := True
  else if SameText(Name, 'exec') then
    Options.NoExecute := False
  else if SameText(Name, 'nosuid') then
    Options.NoSetId := True
  else if SameText(Name, 'suid') then
    Options.NoSetId := False
  else if SameText(Name, 'discard') then
    Options.Discard := True
  else if SameText(Name, 'nodiscard') then
    Options.Discard := False
  else if not (SameText(Name, 'defaults') or SameText(Name, 'atime') or SameText(Name, 'noatime') or
               SameText(Name, 'relatime')) then
    Result := False;
end;

function ApplyValueOption(Name, Value: PChar; var Options: TMountOptions): Boolean;
var
  Mask: LongWord;
begin
  if SameText(Name, 'uid') then
    Result := ParseIdentity(Value, Options.OwnerId)
  else if SameText(Name, 'gid') then
    Result := ParseIdentity(Value, Options.GroupId)
  else if SameText(Name, 'umask') then
  begin
    Result := ParseMode(Value, $1FF, Mask);
    if Result then
    begin
      Options.FileMask := Mask;
      Options.DirectoryMask := Mask;
    end;
  end
  else if SameText(Name, 'fmask') then
    Result := ParseMode(Value, $1FF, Options.FileMask)
  else if SameText(Name, 'dmask') then
    Result := ParseMode(Value, $1FF, Options.DirectoryMask)
  else if SameText(Name, 'mode') then
    Result := ParseMode(Value, $FFF, Options.RootMode)
  else if SameText(Name, 'size') then
    Result := ParseSize(Value, Options)
  else
    Result := False;
end;

function ParseMountOptions(Text: PChar; var Options: TMountOptions; out ErrorPosition: Integer): Boolean;
var
  Position: Integer;
  Start: Integer;
  Option: TOptionText;
  Applied: Boolean;
begin
  ErrorPosition := 0;
  if Text = nil then
    Exit(True);
  Position := 0;
  while Text[Position] <> #0 do
  begin
    Start := Position;
    TakeOption(Text, Position, Option);
    { An empty item (",," or a comma at the end) is skipped. }
    if (Option.Name[0] = #0) and not Option.HasValue then
      Continue;
    if Option.TooLong or (Option.Name[0] = #0) then
      Applied := False
    else if Option.HasValue then
      Applied := ApplyValueOption(@Option.Name[0], @Option.Value[0], Options)
    else
      Applied := ApplyFlagOption(@Option.Name[0], Options);
    if not Applied then
    begin
      ErrorPosition := Start;
      Exit(False);
    end;
  end;
  Result := True;
end;

{ --- Writing --------------------------------------------------------- }

type
  TTextWriter = record
    Text: PChar;
    Capacity: Integer;
    Length: Integer;
  end;

procedure WriteText(var Writer: TTextWriter; Part: PChar);
begin
  while (Part^ <> #0) and (Writer.Length + 1 < Writer.Capacity) do
  begin
    Writer.Text[Writer.Length] := Part^;
    Inc(Writer.Length);
    Inc(Part);
  end;
  Writer.Text[Writer.Length] := #0;
end;

procedure WriteNumber(var Writer: TTextWriter; Value: QWord; Base: LongWord; MinimumDigits: Integer);
var
  Reversed: array[0..23] of Char;
  Digits: array[0..23] of Char;
  Count: Integer;
  Index: Integer;
begin
  Count := 0;
  repeat
    Reversed[Count] := Char(Ord('0') + Value mod Base);
    Value := Value div Base;
    Inc(Count);
  until (Value = 0) and (Count >= MinimumDigits);
  for Index := 0 to Count - 1 do
    Digits[Index] := Reversed[Count - 1 - Index];
  Digits[Count] := #0;
  WriteText(Writer, @Digits[0]);
end;

procedure WriteNamedNumber(var Writer: TTextWriter; Name: PChar; Value: QWord; Base: LongWord;
  MinimumDigits: Integer);
begin
  WriteText(Writer, ',');
  WriteText(Writer, Name);
  WriteText(Writer, '=');
  WriteNumber(Writer, Value, Base, MinimumDigits);
end;

procedure WriteSize(var Writer: TTextWriter; const Options: TMountOptions);
begin
  if Options.SizePercent <> 0 then
  begin
    WriteNamedNumber(Writer, 'size', Options.SizePercent, 10, 1);
    WriteText(Writer, '%');
  end
  else if (Options.SizeLimitBytes and $FFFFF) = 0 then
  begin
    WriteNamedNumber(Writer, 'size', Options.SizeLimitBytes shr 20, 10, 1);
    WriteText(Writer, 'm');
  end
  else if (Options.SizeLimitBytes and $3FF) = 0 then
  begin
    WriteNamedNumber(Writer, 'size', Options.SizeLimitBytes shr 10, 10, 1);
    WriteText(Writer, 'k');
  end
  else
    WriteNamedNumber(Writer, 'size', Options.SizeLimitBytes, 10, 1);
end;

procedure FormatMountOptions(const Options: TMountOptions; OwnerOptions, SizeOptions: Boolean;
  Text: PChar; Capacity: Integer);
var
  Writer: TTextWriter;
begin
  if Capacity <= 0 then
    Exit;
  Writer.Text := Text;
  Writer.Capacity := Capacity;
  Writer.Length := 0;
  Text[0] := #0;
  if Options.ReadOnly then
    WriteText(Writer, 'ro')
  else
    WriteText(Writer, 'rw');
  if Options.NoExecute then
    WriteText(Writer, ',noexec');
  if Options.NoSetId then
    WriteText(Writer, ',nosuid');
  if Options.Discard then
    WriteText(Writer, ',discard');
  if OwnerOptions then
  begin
    WriteNamedNumber(Writer, 'uid', Options.OwnerId, 10, 1);
    WriteNamedNumber(Writer, 'gid', Options.GroupId, 10, 1);
    WriteNamedNumber(Writer, 'fmask', Options.FileMask, 8, 4);
    WriteNamedNumber(Writer, 'dmask', Options.DirectoryMask, 8, 4);
  end;
  if SizeOptions then
  begin
    WriteSize(Writer, Options);
    WriteNamedNumber(Writer, 'mode', Options.RootMode, 8, 4);
  end;
end;

end.
