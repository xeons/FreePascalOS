{
  File names on FAT volumes.

  Every file has a short 8.3 name stored in its directory record (in the
  OEM character set, upper case). Names that do not fit that form also
  get a long name: up to 255 UTF-16 characters spread over extra records
  placed in front of the short record, 13 characters each, linked to the
  short name by a checksum.

  This unit decodes both kinds of names and, for writing, decides whether
  a name needs a long name and generates a unique short name for it the
  way Windows does ("LONGFI~1.TXT").
}
unit FileSystem.Fat.Names;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types,
  FileSystem.Fat.Structures;

type
  { Collects the parts of a long name while its records are read. }
  TLongNameAssembly = record
    Units: array[0..MaximumLongNameEntries * CharactersPerLongNameEntry] of Word;
    ExpectedOrdinal: Integer;
    Checksum: Byte;
    IsValid: Boolean;
  end;

  { How a new name will be stored. }
  TNamePlan = record
    ShortName: TShortName;
    CaseFlags: Byte;
    NeedsLongName: Boolean;
    { Whether the short name was derived lossily and needs a "~N" tail. }
    NeedsNumericTail: Boolean;
    LongNameUnits: array[0..MaximumLongNameCharacters] of Word;
    LongNameLength: Integer;
  end;

function ShortNameChecksum(const Name: TShortName): Byte;
procedure FormatShortName(const DirectoryRecord: TDirectoryRecord; var Name: TFileName);

procedure ResetLongName(var Assembly: TLongNameAssembly);
procedure AddLongNamePart(var Assembly: TLongNameAssembly; const DirectoryRecord: TDirectoryRecord);
function LongNameIsComplete(const Assembly: TLongNameAssembly; const ShortName: TShortName): Boolean;
procedure DecodeLongName(const Assembly: TLongNameAssembly; var Name: TFileName);

{ Analyses a new UTF-8 name. Returns StatusInvalidName for names FAT
  cannot store at all. }
function PlanName(Name: PChar; out Plan: TNamePlan): TFileSystemStatus;

{ Puts "~Number" into the short name of Plan, shortening the base. }
procedure ApplyNumericTail(var Plan: TNamePlan; Number: LongWord);

function LongNameRecordCount(const Plan: TNamePlan): Integer;

{ Builds long name record Index (1 = the one holding the first 13
  characters) for Plan. }
procedure BuildLongNameRecord(const Plan: TNamePlan; Index: Integer; Checksum: Byte;
  out DirectoryRecord: TDirectoryRecord);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Runtime.Unicode;

const
  ShortNameIllegalCharacters = '"*+,/:;<=>?[\]|';
  LongNameIllegalCharacters = '"*/:<>?\|';

{ --- Reading names --------------------------------------------------- }

function ShortNameChecksum(const Name: TShortName): Byte;
var
  Index: Integer;
  Sum: Byte;
begin
  Sum := 0;
  for Index := 0 to ShortNameLength - 1 do
    Sum := Byte(((Sum and 1) shl 7) + (Sum shr 1) + Name[Index]);
  Result := Sum;
end;

procedure FormatShortName(const DirectoryRecord: TDirectoryRecord; var Name: TFileName);
var
  Builder: TUtf8Builder;
  Index: Integer;
  BaseLength: Integer;
  ExtensionLength: Integer;
  Character: Byte;
begin
  BeginUtf8(Builder, @Name[0], MaximumNameBytes);

  BaseLength := 8;
  while (BaseLength > 0) and (DirectoryRecord.Name[BaseLength - 1] = Ord(' ')) do
    Dec(BaseLength);
  ExtensionLength := 3;
  while (ExtensionLength > 0) and (DirectoryRecord.Name[8 + ExtensionLength - 1] = Ord(' ')) do
    Dec(ExtensionLength);

  for Index := 0 to BaseLength - 1 do
  begin
    Character := DirectoryRecord.Name[Index];
    if (Index = 0) and (Character = EntryKanjiE5) then
      Character := EntryDeleted;
    if ((DirectoryRecord.CaseFlags and CaseLowerBase) <> 0) and
       (Character >= Ord('A')) and (Character <= Ord('Z')) then
      Character := Character + 32;
    AppendCodePoint(Builder, Character);
  end;

  if ExtensionLength > 0 then
  begin
    AppendCodePoint(Builder, Ord('.'));
    for Index := 8 to 8 + ExtensionLength - 1 do
    begin
      Character := DirectoryRecord.Name[Index];
      if ((DirectoryRecord.CaseFlags and CaseLowerExtension) <> 0) and
         (Character >= Ord('A')) and (Character <= Ord('Z')) then
        Character := Character + 32;
      AppendCodePoint(Builder, Character);
    end;
  end;
end;

procedure ResetLongName(var Assembly: TLongNameAssembly);
begin
  Assembly.IsValid := False;
  Assembly.ExpectedOrdinal := 0;
end;

procedure AddLongNamePart(var Assembly: TLongNameAssembly; const DirectoryRecord: TDirectoryRecord);
var
  Part: PLongNameRecord;
  Ordinal: Integer;
  Position: Integer;
  Index: Integer;
begin
  Part := PLongNameRecord(@DirectoryRecord);
  Ordinal := Part^.Ordinal and LongNameOrdinalMask;

  if (Part^.Ordinal and LongNameLastEntryFlag) <> 0 then
  begin
    { The record with the highest ordinal comes first and starts a name. }
    if (Ordinal < 1) or (Ordinal > MaximumLongNameEntries) then
    begin
      ResetLongName(Assembly);
      Exit;
    end;
    FillMemory(@Assembly.Units[0], SizeOf(Assembly.Units), 0);
    Assembly.Checksum := Part^.Checksum;
    Assembly.IsValid := True;
  end
  else if (not Assembly.IsValid) or (Ordinal <> Assembly.ExpectedOrdinal) or
          (Part^.Checksum <> Assembly.Checksum) then
  begin
    ResetLongName(Assembly);
    Exit;
  end;

  Position := (Ordinal - 1) * CharactersPerLongNameEntry;
  for Index := 0 to 4 do
    Assembly.Units[Position + Index] := Part^.NamePart1[Index];
  for Index := 0 to 5 do
    Assembly.Units[Position + 5 + Index] := Part^.NamePart2[Index];
  for Index := 0 to 1 do
    Assembly.Units[Position + 11 + Index] := Part^.NamePart3[Index];

  Assembly.ExpectedOrdinal := Ordinal - 1;
end;

function LongNameIsComplete(const Assembly: TLongNameAssembly; const ShortName: TShortName): Boolean;
begin
  Result := Assembly.IsValid and (Assembly.ExpectedOrdinal = 0) and
    (Assembly.Checksum = ShortNameChecksum(ShortName));
end;

procedure DecodeLongName(const Assembly: TLongNameAssembly; var Name: TFileName);
var
  Builder: TUtf8Builder;
begin
  BeginUtf8(Builder, @Name[0], MaximumNameBytes);
  { Stops at the zero after the name; unused units hold $FFFF after it. }
  AppendUtf16(Builder, @Assembly.Units[0], Length(Assembly.Units));
end;

{ --- Writing names --------------------------------------------------- }

function CharacterIsIn(Character: LongWord; Characters: PChar): Boolean;
begin
  while Characters^ <> #0 do
  begin
    if Character = Ord(Characters^) then
      Exit(True);
    Inc(Characters);
  end;
  Result := False;
end;

function IsAsciiLetterLower(Character: LongWord): Boolean;
begin
  Result := (Character >= Ord('a')) and (Character <= Ord('z'));
end;

function IsAsciiLetterUpper(Character: LongWord): Boolean;
begin
  Result := (Character >= Ord('A')) and (Character <= Ord('Z'));
end;

{ Fills one part (base or extension) of the short name from UTF-16
  units. Returns how the letter case looked: 1 = all lower, 2 = all upper,
  3 = mixed, 0 = no letters. Sets Lossy when characters were dropped or
  replaced. }
function FillShortNamePart(const Units: array of Word; First, Count: Integer;
  var ShortName: TShortName; Destination, Capacity: Integer; var Lossy: Boolean): Integer;
var
  Index: Integer;
  Written: Integer;
  Character: LongWord;
begin
  Result := 0;
  Written := 0;
  for Index := First to First + Count - 1 do
  begin
    Character := Units[Index];
    if (Character = Ord(' ')) or (Character = Ord('.')) then
    begin
      Lossy := True;
      Continue;
    end;
    if Written >= Capacity then
    begin
      Lossy := True;
      Break;
    end;

    if IsAsciiLetterLower(Character) then
    begin
      Result := Result or 1;
      Character := Character - 32;
    end
    else if IsAsciiLetterUpper(Character) then
      Result := Result or 2;

    if (Character >= $80) or (Character < $20) or CharacterIsIn(Character, ShortNameIllegalCharacters) then
    begin
      Character := Ord('_');
      Lossy := True;
    end;

    ShortName[Destination + Written] := Byte(Character);
    Inc(Written);
  end;
end;

function PlanName(Name: PChar; out Plan: TNamePlan): TFileSystemStatus;
var
  Length: PtrInt;
  Index: Integer;
  LastDot: Integer;
  BaseCount: Integer;
  ExtensionCount: Integer;
  BaseCase: Integer;
  ExtensionCase: Integer;
  Lossy: Boolean;
begin
  FillMemory(@Plan, SizeOf(Plan), 0);
  FillMemory(@Plan.ShortName[0], ShortNameLength, Ord(' '));

  Length := Utf8ToUtf16(Name, @Plan.LongNameUnits[0], MaximumLongNameCharacters);
  if Length <= 0 then
    Exit(StatusNameTooLong);
  Plan.LongNameLength := Integer(Length);

  for Index := 0 to Plan.LongNameLength - 1 do
  begin
    if (Plan.LongNameUnits[Index] < $20) or
       CharacterIsIn(Plan.LongNameUnits[Index], LongNameIllegalCharacters) then
      Exit(StatusInvalidName);
  end;
  { Trailing dots and spaces are not allowed in FAT names. }
  if (Plan.LongNameUnits[Plan.LongNameLength - 1] = Ord('.')) or
     (Plan.LongNameUnits[Plan.LongNameLength - 1] = Ord(' ')) then
    Exit(StatusInvalidName);

  LastDot := -1;
  for Index := 0 to Plan.LongNameLength - 1 do
  begin
    if Plan.LongNameUnits[Index] = Ord('.') then
      LastDot := Index;
  end;
  { A leading dot (".profile") starts the base, not an extension. }
  if LastDot = 0 then
    LastDot := -1;

  if LastDot >= 0 then
  begin
    BaseCount := LastDot;
    ExtensionCount := Plan.LongNameLength - LastDot - 1;
  end
  else
  begin
    BaseCount := Plan.LongNameLength;
    ExtensionCount := 0;
  end;

  Lossy := False;
  BaseCase := FillShortNamePart(Plan.LongNameUnits, 0, BaseCount, Plan.ShortName, 0, 8, Lossy);
  ExtensionCase := 0;
  if ExtensionCount > 0 then
    ExtensionCase := FillShortNamePart(Plan.LongNameUnits, LastDot + 1, ExtensionCount,
      Plan.ShortName, 8, 3, Lossy);

  if Plan.ShortName[0] = Ord(' ') then
  begin
    { Nothing usable in the base, for example ".txt". }
    Plan.ShortName[0] := Ord('_');
    Lossy := True;
  end;
  if Plan.ShortName[0] = EntryDeleted then
    Plan.ShortName[0] := EntryKanjiE5;

  Plan.NeedsNumericTail := Lossy;
  { Mixed case within one part can only be kept by a long name. }
  Plan.NeedsLongName := Lossy or (BaseCase = 3) or (ExtensionCase = 3);
  if not Plan.NeedsLongName then
  begin
    if BaseCase = 1 then
      Plan.CaseFlags := Plan.CaseFlags or CaseLowerBase;
    if ExtensionCase = 1 then
      Plan.CaseFlags := Plan.CaseFlags or CaseLowerExtension;
  end;
  Result := StatusSuccess;
end;

procedure ApplyNumericTail(var Plan: TNamePlan; Number: LongWord);
var
  NumberText: TNumberText;
  Digits: PChar;
  TailLength: Integer;
  BaseLength: Integer;
  Index: Integer;
begin
  Digits := FormatDecimal(Number, NumberText);
  TailLength := Integer(TextLength(Digits)) + 1;

  BaseLength := 8;
  while (BaseLength > 0) and (Plan.ShortName[BaseLength - 1] = Ord(' ')) do
    Dec(BaseLength);
  if BaseLength > 8 - TailLength then
    BaseLength := 8 - TailLength;

  Plan.ShortName[BaseLength] := Ord('~');
  for Index := 0 to TailLength - 2 do
    Plan.ShortName[BaseLength + 1 + Index] := Byte(Digits[Index]);
  for Index := BaseLength + TailLength to 7 do
    Plan.ShortName[Index] := Ord(' ');
end;

function LongNameRecordCount(const Plan: TNamePlan): Integer;
begin
  if not Plan.NeedsLongName then
    Exit(0);
  Result := (Plan.LongNameLength + CharactersPerLongNameEntry - 1) div CharactersPerLongNameEntry;
end;

function LongNameUnitAt(const Plan: TNamePlan; Position: Integer): Word;
begin
  if Position < Plan.LongNameLength then
    Result := Plan.LongNameUnits[Position]
  else if Position = Plan.LongNameLength then
    Result := 0       { terminator }
  else
    Result := $FFFF;  { padding }
end;

procedure BuildLongNameRecord(const Plan: TNamePlan; Index: Integer; Checksum: Byte;
  out DirectoryRecord: TDirectoryRecord);
var
  Part: PLongNameRecord;
  Position: Integer;
  CharacterIndex: Integer;
begin
  FillMemory(@DirectoryRecord, SizeOf(DirectoryRecord), 0);
  Part := PLongNameRecord(@DirectoryRecord);
  Part^.Ordinal := Byte(Index);
  if Index = LongNameRecordCount(Plan) then
    Part^.Ordinal := Part^.Ordinal or LongNameLastEntryFlag;
  Part^.Attributes := AttributeLongName;
  Part^.EntryType := 0;
  Part^.Checksum := Checksum;
  Part^.FirstClusterLow := 0;

  Position := (Index - 1) * CharactersPerLongNameEntry;
  for CharacterIndex := 0 to 4 do
    Part^.NamePart1[CharacterIndex] := LongNameUnitAt(Plan, Position + CharacterIndex);
  for CharacterIndex := 0 to 5 do
    Part^.NamePart2[CharacterIndex] := LongNameUnitAt(Plan, Position + 5 + CharacterIndex);
  for CharacterIndex := 0 to 1 do
    Part^.NamePart3[CharacterIndex] := LongNameUnitAt(Plan, Position + 11 + CharacterIndex);
end;

end.
