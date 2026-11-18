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
  HID report descriptors: which reports a HID interface sends, and where
  a pointing device's axes and buttons and a keyboard's keys are in
  them.

  A report descriptor is a list of items. Global items (usage page,
  logical minimum and maximum, report size, count and id) stay in force
  until changed; local items (usages, usage ranges) apply to the next
  main item only. An Input main item lays out Report Count fields of
  Report Size bits each, one after another, each taking the next usage;
  its flags say whether they are constant (padding), variable (one
  field per usage) or an array (each field holds the index of a usage
  in force, a key held), and relative or absolute.

  ParseHidDescription notes, report by report: the one holding the
  Generic Desktop X and Y usages (a pointer: X, Y, the wheel, the first
  buttons) and the one holding keyboard keys (the modifier bits E0h-E7h,
  and a key array or a bitmap of keys). A descriptor with report ids
  sends reports that start with their id: HidReportTargets says which
  of the two a report is for (neither for, say, consumer or system
  control reports). A keyboard's report is turned into the boot
  protocol's 8 bytes (ReadKeyboardAsBoot), so one keyboard driver
  handles both protocols.

  Plain Pascal with no kernel dependencies (the host test
  tools/UsbDescriptorTest uses it too).
}
unit Drivers.HidReports;

{$mode objfpc}
{$pointermath on}

interface

const
  MaximumPointerButtons = 5;
  { The boot protocol's keyboard report: modifiers, a reserved byte and
    up to six keys. }
  BootKeyboardReportSize = 8;
  BootKeyboardKeys = 6;
  { The usage a keyboard reports in every key slot when too many keys
    are held to tell which. }
  KeyUsageErrorRollOver = $01;
  { Reports a descriptor may describe (by id): kept small, the parser
    runs on kernel stacks. }
  MaximumHidReports = 8;

type
  THidField = record
    Present: Boolean;
    Relative: Boolean;
    BitSize: Byte;
    BitOffset: LongWord;
    LogicalMinimum: LongInt;
    LogicalMaximum: LongInt;
  end;

  THidPointerLayout = record
    { Reports start with their id byte if the descriptor uses ids. }
    UsesReportIds: Boolean;
    ReportId: Byte;
    X: THidField;
    Y: THidField;
    Wheel: THidField;
    Buttons: array[1..MaximumPointerButtons] of THidField;
  end;

  THidKeyboardLayout = record
    UsesReportIds: Boolean;
    ReportId: Byte;
    { The report's length without its id byte. }
    ReportBytes: LongWord;
    { Left Control, Shift, Alt, GUI, then the right ones (E0h-E7h). }
    Modifiers: array[0..7] of THidField;
    { A key array: KeyArray is its first entry (the next ones follow,
      KeyArray.BitSize bits each), KeyArrayCount entries; an entry's
      value V means usage KeyArrayUsageMinimum + V - its logical
      minimum. }
    KeyArray: THidField;
    KeyArrayCount: LongWord;
    KeyArrayUsageMinimum: LongWord;
    { Or a bitmap: one bit per key from KeyBitmapUsageMinimum. }
    KeyBitmapOffset: LongWord;
    KeyBitmapCount: LongWord;
    KeyBitmapUsageMinimum: LongWord;
  end;

  THidDescription = record
    UsesReportIds: Boolean;
    HasPointer: Boolean;
    PointerLayout: THidPointerLayout;
    HasKeyboard: Boolean;
    KeyboardLayout: THidKeyboardLayout;
    { Every input report's id (0 without ids), for the log. }
    ReportCount: Integer;
    ReportIds: array[0..MaximumHidReports - 1] of Byte;
  end;

  THidReportTarget = (HidTargetKeyboard, HidTargetPointer);
  THidReportTargets = set of THidReportTarget;

  THidPointerState = record
    X: LongInt;
    Y: LongInt;
    Wheel: LongInt;
    { Bit N set: button N (1-5) held. }
    Buttons: LongWord;
  end;

  TBootKeyboardReport = array[0..BootKeyboardReportSize - 1] of Byte;

  { How a HID interface is driven. }
  THidInterfaceMode = (
    HidModeNone,
    { Boot protocol keyboard reports (8 bytes, no descriptor needed). }
    HidModeBootKeyboard,
    { Boot protocol mouse reports (buttons, X, Y), when the descriptor
      could not be used. }
    HidModeBootMouse,
    { Report protocol, the reports the descriptor describes. }
    HidModeReports);

{ Parses a report descriptor; True if it describes a pointer or a
  keyboard report. }
function ParseHidDescription(Data: PByte; Length: LongWord; out Description: THidDescription): Boolean;
{ Just the pointer: True if the descriptor has a report with X and Y. }
function ParsePointerLayout(Data: PByte; Length: LongWord; out Layout: THidPointerLayout): Boolean;
{ Field's value in Report (whose first byte is the id, if ids are used),
  sign extended if its logical minimum is negative. 0 if the report is
  too short. }
function ReadHidField(UsesReportIds: Boolean; const Field: THidField; Report: PByte;
  ReportLength: LongWord): LongInt;
{ Which layouts a report received is for (by its id). }
function HidReportTargets(const Description: THidDescription; Report: PByte; ReportLength: LongWord): THidReportTargets;
procedure ReadPointerState(const Layout: THidPointerLayout; Report: PByte; ReportLength: LongWord;
  out State: THidPointerState);
{ A keyboard report as the boot protocol's (modifier bits, 0, up to six
  key usages); False if the report is too short. }
function ReadKeyboardAsBoot(const Layout: THidKeyboardLayout; Report: PByte; ReportLength: LongWord;
  out Boot: TBootKeyboardReport): Boolean;
{ The boot mouse report's layout: buttons 1-3 in the first byte, X and
  Y relative in the next two. }
procedure BootMouseLayout(out Layout: THidPointerLayout);
{ How to drive a HID interface of this subclass and protocol whose
  report descriptor was parsed (Parsed) into Description: a boot
  keyboard in the boot protocol unless its descriptor puts a pointer
  beside the keyboard (by report id); else the reports the descriptor
  describes; a boot mouse whose descriptor is of no use in the boot
  protocol. }
function ChooseHidMode(Subclass, Protocol: Byte; Parsed: Boolean; const Description: THidDescription): THidInterfaceMode;

implementation

uses
  Runtime.Memory;

const
  ItemTypeMain = 0;
  ItemTypeGlobal = 1;
  ItemTypeLocal = 2;
  LongItemPrefix = $FE;

  MainInput = $8;
  GlobalUsagePage = $0;
  GlobalLogicalMinimum = $1;
  GlobalLogicalMaximum = $2;
  GlobalReportSize = $7;
  GlobalReportId = $8;
  GlobalReportCount = $9;
  GlobalPush = $A;
  GlobalPop = $B;
  LocalUsage = $0;
  LocalUsageMinimum = $1;
  LocalUsageMaximum = $2;

  InputConstant = $01;
  InputVariable = $02;
  InputRelative = $04;

  PageGenericDesktop = $01;
  PageKeyboard = $07;
  PageButton = $09;
  UsageX = $30;
  UsageY = $31;
  UsageWheel = $38;
  UsageLeftControl = $E0;
  UsageRightGui = $E7;

  SubclassBoot = 1;
  ProtocolKeyboard = 1;
  ProtocolMouse = 2;

  MaximumUsages = 32;
  MaximumStackDepth = 4;

type
  TGlobals = record
    UsagePage: LongWord;
    LogicalMinimum: LongInt;
    LogicalMaximum: LongInt;
    ReportSize: LongWord;
    ReportId: Byte;
    ReportCount: LongWord;
  end;

  TLocals = record
    Usages: array[0..MaximumUsages - 1] of LongWord;
    UsageCount: Integer;
    UsageMinimum: LongWord;
    UsageMaximum: LongWord;
    HasUsageRange: Boolean;
  end;

  { One report's fields as found (the pointer's and the keyboard's
    reports are picked after). }
  PReportFields = ^TReportFields;
  TReportFields = record
    Id: Byte;
    BitOffset: LongWord;
    PointerFields: THidPointerLayout;
    KeyboardFields: THidKeyboardLayout;
    HasX: Boolean;
    HasY: Boolean;
    HasKeys: Boolean;
  end;

  TReportTable = record
    Reports: array[0..MaximumHidReports - 1] of TReportFields;
    Count: Integer;
  end;

{ The report with Id, added if new; nil if the table is full. }
function ReportWithId(var Table: TReportTable; Id: Byte): PReportFields;
var
  Index: Integer;
begin
  for Index := 0 to Table.Count - 1 do
    if Table.Reports[Index].Id = Id then
      Exit(@Table.Reports[Index]);
  if Table.Count = MaximumHidReports then
    Exit(nil);
  ZeroMemory(@Table.Reports[Table.Count], SizeOf(TReportFields));
  Table.Reports[Table.Count].Id := Id;
  Result := @Table.Reports[Table.Count];
  Inc(Table.Count);
end;

{ The item's data, unsigned and sign extended. }
procedure ItemData(Data: PByte; Size: Integer; out Unsigned: LongWord; out Signed: LongInt);
begin
  Unsigned := 0;
  Signed := 0;
  case Size of
    1:
      begin
        Unsigned := Data[0];
        Signed := ShortInt(Data[0]);
      end;
    2:
      begin
        Unsigned := Data[0] or (LongWord(Data[1]) shl 8);
        Signed := SmallInt(Unsigned);
      end;
    4:
      begin
        Unsigned := Data[0] or (LongWord(Data[1]) shl 8) or (LongWord(Data[2]) shl 16) or (LongWord(Data[3]) shl 24);
        Signed := LongInt(Unsigned);
      end;
  end;
end;

{ The usage of an Input item's field Index (the usages listed, then the
  range, the last usage repeating). }
function UsageAt(const Locals: TLocals; Index: LongWord): LongWord;
begin
  if Index < LongWord(Locals.UsageCount) then
    Result := Locals.Usages[Index]
  else if Locals.HasUsageRange and (Locals.UsageMinimum + Index <= Locals.UsageMaximum) then
    Result := Locals.UsageMinimum + Index
  else if Locals.UsageCount > 0 then
    Result := Locals.Usages[Locals.UsageCount - 1]
  else
    Result := 0;
end;

{ A usage of a short item takes the current page. }
function FullUsage(Unsigned: LongWord; Size: Integer; const Globals: TGlobals): LongWord;
begin
  Result := Unsigned;
  if Size <= 2 then
    Result := Result or (Globals.UsagePage shl 16);
end;

procedure NoteKeyboardVariable(var Report: TReportFields; Usage: LongWord; const Field: THidField);
var
  Code: LongWord;
  Keyboard: ^THidKeyboardLayout;
begin
  Keyboard := @Report.KeyboardFields;
  Code := Usage and $FFFF;
  if (Code >= UsageLeftControl) and (Code <= UsageRightGui) then
    Keyboard^.Modifiers[Code - UsageLeftControl] := Field
  else if Field.BitSize = 1 then
  begin
    { A bitmap of keys: one bit after another, usage after usage. }
    if Keyboard^.KeyBitmapCount = 0 then
    begin
      Keyboard^.KeyBitmapOffset := Field.BitOffset;
      Keyboard^.KeyBitmapUsageMinimum := Code;
      Keyboard^.KeyBitmapCount := 1;
      Report.HasKeys := True;
    end
    else if (Field.BitOffset = Keyboard^.KeyBitmapOffset + Keyboard^.KeyBitmapCount) and
            (Code = Keyboard^.KeyBitmapUsageMinimum + Keyboard^.KeyBitmapCount) then
      Inc(Keyboard^.KeyBitmapCount);
  end;
end;

procedure NotePointerVariable(var Report: TReportFields; Usage: LongWord; const Field: THidField);
var
  Button: LongWord;
begin
  if Usage = (PageGenericDesktop shl 16) or UsageX then
  begin
    Report.PointerFields.X := Field;
    Report.HasX := True;
  end
  else if Usage = (PageGenericDesktop shl 16) or UsageY then
  begin
    Report.PointerFields.Y := Field;
    Report.HasY := True;
  end
  else if Usage = (PageGenericDesktop shl 16) or UsageWheel then
    Report.PointerFields.Wheel := Field
  else if (Usage shr 16) = PageButton then
  begin
    Button := Usage and $FFFF;
    if (Button >= 1) and (Button <= MaximumPointerButtons) then
      Report.PointerFields.Buttons[Button] := Field;
  end;
end;

procedure FillField(out Field: THidField; const Globals: TGlobals; BitOffset: LongWord; Flags: LongWord);
begin
  Field.Present := True;
  Field.BitOffset := BitOffset;
  Field.BitSize := Byte(Globals.ReportSize);
  Field.LogicalMinimum := Globals.LogicalMinimum;
  Field.LogicalMaximum := Globals.LogicalMaximum;
  Field.Relative := (Flags and InputRelative) <> 0;
end;

{ An array of keyboard usages (a range on the keyboard page): the
  report's key array, if it has none yet. }
procedure NoteKeyArray(var Report: TReportFields; const Globals: TGlobals; const Locals: TLocals; Flags: LongWord);
begin
  if not Locals.HasUsageRange or ((Locals.UsageMinimum shr 16) <> PageKeyboard) or
     (Report.KeyboardFields.KeyArrayCount <> 0) then
    Exit;
  FillField(Report.KeyboardFields.KeyArray, Globals, Report.BitOffset, Flags);
  Report.KeyboardFields.KeyArrayCount := Globals.ReportCount;
  Report.KeyboardFields.KeyArrayUsageMinimum := Locals.UsageMinimum and $FFFF;
  Report.HasKeys := True;
end;

{ An Input item: its fields laid out in its report. }
procedure AddInputItem(var Table: TReportTable; const Globals: TGlobals; const Locals: TLocals; Flags: LongWord);
var
  Report: PReportFields;
  Index: LongWord;
  Usage: LongWord;
  Field: THidField;
begin
  Report := ReportWithId(Table, Globals.ReportId);
  if (Report = nil) or (Globals.ReportCount = 0) or (Globals.ReportSize = 0) or (Globals.ReportSize > 32) then
    Exit;
  if ((Flags and InputConstant) = 0) and ((Flags and InputVariable) = 0) then
    NoteKeyArray(Report^, Globals, Locals, Flags)
  else if (Flags and InputConstant) = 0 then
    for Index := 0 to Globals.ReportCount - 1 do
    begin
      Usage := UsageAt(Locals, Index);
      FillField(Field, Globals, Report^.BitOffset + Index * Globals.ReportSize, Flags);
      if (Usage shr 16) = PageKeyboard then
        NoteKeyboardVariable(Report^, Usage, Field)
      else
        NotePointerVariable(Report^, Usage, Field);
    end;
  Report^.BitOffset := Report^.BitOffset + Globals.ReportCount * Globals.ReportSize;
end;

procedure HandleGlobalItem(Tag: Integer; Unsigned: LongWord; Signed: LongInt; var Globals: TGlobals;
  var Stack: array of TGlobals; var Depth: Integer; var UsesIds: Boolean);
begin
  case Tag of
    GlobalUsagePage: Globals.UsagePage := Unsigned;
    GlobalLogicalMinimum: Globals.LogicalMinimum := Signed;
    GlobalLogicalMaximum:
      { A maximum read as negative with a non-negative minimum is a
        large unsigned value. }
      if (Signed < 0) and (Globals.LogicalMinimum >= 0) then
        Globals.LogicalMaximum := LongInt(Unsigned)
      else
        Globals.LogicalMaximum := Signed;
    GlobalReportSize: Globals.ReportSize := Unsigned;
    GlobalReportId:
      begin
        Globals.ReportId := Byte(Unsigned);
        UsesIds := True;
      end;
    GlobalReportCount: Globals.ReportCount := Unsigned;
    GlobalPush:
      if Depth <= High(Stack) then
      begin
        Stack[Depth] := Globals;
        Inc(Depth);
      end;
    GlobalPop:
      if Depth > 0 then
      begin
        Dec(Depth);
        Globals := Stack[Depth];
      end;
  end;
end;

procedure HandleLocalItem(Tag: Integer; Unsigned: LongWord; Size: Integer; const Globals: TGlobals;
  var Locals: TLocals);
begin
  case Tag of
    LocalUsage:
      if Locals.UsageCount < MaximumUsages then
      begin
        Locals.Usages[Locals.UsageCount] := FullUsage(Unsigned, Size, Globals);
        Inc(Locals.UsageCount);
      end;
    LocalUsageMinimum:
      begin
        Locals.UsageMinimum := FullUsage(Unsigned, Size, Globals);
        Locals.HasUsageRange := True;
      end;
    LocalUsageMaximum:
      Locals.UsageMaximum := FullUsage(Unsigned, Size, Globals);
  end;
end;

{ The pointer's and the keyboard's reports from the table. }
procedure PickReports(var Table: TReportTable; UsesIds: Boolean; var Description: THidDescription);
var
  Index: Integer;
  Report: PReportFields;
begin
  Description.UsesReportIds := UsesIds;
  Description.ReportCount := Table.Count;
  for Index := 0 to Table.Count - 1 do
  begin
    Report := @Table.Reports[Index];
    Description.ReportIds[Index] := Report^.Id;
    if Report^.HasX and Report^.HasY and not Description.HasPointer then
    begin
      Description.HasPointer := True;
      Description.PointerLayout := Report^.PointerFields;
      Description.PointerLayout.UsesReportIds := UsesIds;
      Description.PointerLayout.ReportId := Report^.Id;
    end;
    if Report^.HasKeys and not Description.HasKeyboard then
    begin
      Description.HasKeyboard := True;
      Description.KeyboardLayout := Report^.KeyboardFields;
      Description.KeyboardLayout.UsesReportIds := UsesIds;
      Description.KeyboardLayout.ReportId := Report^.Id;
      Description.KeyboardLayout.ReportBytes := (Report^.BitOffset + 7) div 8;
    end;
  end;
end;

function ParseHidDescription(Data: PByte; Length: LongWord; out Description: THidDescription): Boolean;
var
  Globals: TGlobals;
  Stack: array[0..MaximumStackDepth - 1] of TGlobals;
  Depth: Integer;
  Locals: TLocals;
  Table: TReportTable;
  Position: LongWord;
  Prefix: Byte;
  Size: Integer;
  Tag: Integer;
  Unsigned: LongWord;
  Signed: LongInt;
  UsesIds: Boolean;
begin
  ZeroMemory(@Description, SizeOf(Description));
  ZeroMemory(@Globals, SizeOf(Globals));
  ZeroMemory(@Locals, SizeOf(Locals));
  Table.Count := 0;
  Depth := 0;
  UsesIds := False;
  Position := 0;
  while Position < Length do
  begin
    Prefix := Data[Position];
    if Prefix = LongItemPrefix then
    begin
      { Long items: skipped (their size is in the next byte). }
      if Position + 1 >= Length then
        Break;
      Position := Position + 3 + Data[Position + 1];
      Continue;
    end;
    Size := Prefix and 3;
    if Size = 3 then
      Size := 4;
    if Position + 1 + LongWord(Size) > Length then
      Break;
    Tag := Prefix shr 4;
    ItemData(Data + Position + 1, Size, Unsigned, Signed);
    case (Prefix shr 2) and 3 of
      ItemTypeGlobal: HandleGlobalItem(Tag, Unsigned, Signed, Globals, Stack, Depth, UsesIds);
      ItemTypeLocal: HandleLocalItem(Tag, Unsigned, Size, Globals, Locals);
      ItemTypeMain:
        begin
          if Tag = MainInput then
            AddInputItem(Table, Globals, Locals, Unsigned);
          { Local items end with every main item. }
          Locals.UsageCount := 0;
          Locals.HasUsageRange := False;
        end;
    end;
    Position := Position + 1 + LongWord(Size);
  end;
  PickReports(Table, UsesIds, Description);
  Result := Description.HasPointer or Description.HasKeyboard;
end;

function ParsePointerLayout(Data: PByte; Length: LongWord; out Layout: THidPointerLayout): Boolean;
var
  Description: THidDescription;
begin
  ParseHidDescription(Data, Length, Description);
  Layout := Description.PointerLayout;
  Result := Description.HasPointer;
end;

function ReadHidField(UsesReportIds: Boolean; const Field: THidField; Report: PByte;
  ReportLength: LongWord): LongInt;
var
  Bit: LongWord;
  Start: LongWord;
  Value: LongWord;
  Index: LongWord;
  Mask: LongWord;
begin
  Result := 0;
  if not Field.Present or (Field.BitSize = 0) or (Field.BitSize > 32) then
    Exit;
  Start := Field.BitOffset;
  if UsesReportIds then
    Start := Start + 8;
  if (Start + Field.BitSize + 7) div 8 > ReportLength then
    Exit;
  Value := 0;
  for Index := 0 to Field.BitSize - 1 do
  begin
    Bit := Start + Index;
    if (Report[Bit div 8] and (1 shl (Bit mod 8))) <> 0 then
      Value := Value or (LongWord(1) shl Index);
  end;
  if (Field.LogicalMinimum < 0) and (Field.BitSize < 32) and ((Value and (LongWord(1) shl (Field.BitSize - 1))) <> 0) then
  begin
    { The bits above the field, set: computed in LongWord throughout. }
    Mask := LongWord(1) shl Field.BitSize;
    Mask := Mask - LongWord(1);
    Value := Value or (not Mask);
  end;
  Result := LongInt(Value);
end;

function HidReportTargets(const Description: THidDescription; Report: PByte; ReportLength: LongWord): THidReportTargets;
var
  Id: Byte;
begin
  Result := [];
  if ReportLength = 0 then
    Exit;
  Id := 0;
  if Description.UsesReportIds then
    Id := Report[0];
  if Description.HasKeyboard and (Description.KeyboardLayout.ReportId = Id) then
    Include(Result, HidTargetKeyboard);
  if Description.HasPointer and (Description.PointerLayout.ReportId = Id) then
    Include(Result, HidTargetPointer);
end;

procedure ReadPointerState(const Layout: THidPointerLayout; Report: PByte; ReportLength: LongWord;
  out State: THidPointerState);
var
  Button: Integer;
begin
  State.X := ReadHidField(Layout.UsesReportIds, Layout.X, Report, ReportLength);
  State.Y := ReadHidField(Layout.UsesReportIds, Layout.Y, Report, ReportLength);
  State.Wheel := ReadHidField(Layout.UsesReportIds, Layout.Wheel, Report, ReportLength);
  State.Buttons := 0;
  for Button := 1 to MaximumPointerButtons do
    if ReadHidField(Layout.UsesReportIds, Layout.Buttons[Button], Report, ReportLength) <> 0 then
      State.Buttons := State.Buttons or (LongWord(1) shl Button);
end;

{ Usage held: a modifier sets its bit, another key takes the next free
  slot (keys past six are dropped). }
procedure AddBootUsage(var Boot: TBootKeyboardReport; Usage: LongWord; var KeyCount: Integer);
begin
  if (Usage >= UsageLeftControl) and (Usage <= UsageRightGui) then
    Boot[0] := Boot[0] or (1 shl (Usage - UsageLeftControl))
  else if (Usage <> 0) and (Usage <= $FF) and (KeyCount < BootKeyboardKeys) then
  begin
    Boot[2 + KeyCount] := Byte(Usage);
    Inc(KeyCount);
  end;
end;

procedure ReadKeyArray(const Layout: THidKeyboardLayout; Report: PByte; ReportLength: LongWord;
  var Boot: TBootKeyboardReport; var KeyCount: Integer);
var
  Entry: THidField;
  Index: LongWord;
  Value: LongInt;
begin
  Entry := Layout.KeyArray;
  Index := 0;
  while Index < Layout.KeyArrayCount do
  begin
    Entry.BitOffset := Layout.KeyArray.BitOffset + Index * Entry.BitSize;
    Value := ReadHidField(Layout.UsesReportIds, Entry, Report, ReportLength);
    if (Value >= Entry.LogicalMinimum) and (Value <= Entry.LogicalMaximum) then
      AddBootUsage(Boot, LongWord(Int64(Layout.KeyArrayUsageMinimum) + Value - Entry.LogicalMinimum), KeyCount);
    Inc(Index);
  end;
end;

procedure ReadKeyBitmap(const Layout: THidKeyboardLayout; Report: PByte; var Boot: TBootKeyboardReport;
  var KeyCount: Integer);
var
  Index: LongWord;
  Bit: LongWord;
begin
  Index := 0;
  while Index < Layout.KeyBitmapCount do
  begin
    Bit := Layout.KeyBitmapOffset + Index;
    if Layout.UsesReportIds then
      Bit := Bit + 8;
    if (Report[Bit div 8] and (1 shl (Bit mod 8))) <> 0 then
      AddBootUsage(Boot, Layout.KeyBitmapUsageMinimum + Index, KeyCount);
    Inc(Index);
  end;
end;

function ReadKeyboardAsBoot(const Layout: THidKeyboardLayout; Report: PByte; ReportLength: LongWord;
  out Boot: TBootKeyboardReport): Boolean;
var
  Bytes: LongWord;
  Modifier: Integer;
  KeyCount: Integer;
  Index: Integer;
begin
  ZeroMemory(@Boot[0], SizeOf(Boot));
  Bytes := Layout.ReportBytes;
  if Layout.UsesReportIds then
    Inc(Bytes);
  if ReportLength < Bytes then
    Exit(False);
  for Modifier := 0 to 7 do
    if ReadHidField(Layout.UsesReportIds, Layout.Modifiers[Modifier], Report, ReportLength) <> 0 then
      Boot[0] := Boot[0] or (1 shl Modifier);
  KeyCount := 0;
  ReadKeyArray(Layout, Report, ReportLength, Boot, KeyCount);
  ReadKeyBitmap(Layout, Report, Boot, KeyCount);
  { Too many keys: every slot says so, as in the boot protocol. }
  for Index := 2 to BootKeyboardReportSize - 1 do
    if Boot[Index] = KeyUsageErrorRollOver then
    begin
      FillMemory(@Boot[2], BootKeyboardKeys, KeyUsageErrorRollOver);
      Break;
    end;
  Result := True;
end;

procedure BootMouseLayout(out Layout: THidPointerLayout);
var
  Button: Integer;
begin
  ZeroMemory(@Layout, SizeOf(Layout));
  for Button := 1 to 3 do
  begin
    Layout.Buttons[Button].Present := True;
    Layout.Buttons[Button].BitOffset := Button - 1;
    Layout.Buttons[Button].BitSize := 1;
    Layout.Buttons[Button].LogicalMaximum := 1;
  end;
  Layout.X.Present := True;
  Layout.X.Relative := True;
  Layout.X.BitOffset := 8;
  Layout.X.BitSize := 8;
  Layout.X.LogicalMinimum := -127;
  Layout.X.LogicalMaximum := 127;
  Layout.Y := Layout.X;
  Layout.Y.BitOffset := 16;
end;

function ChooseHidMode(Subclass, Protocol: Byte; Parsed: Boolean; const Description: THidDescription): THidInterfaceMode;
var
  IsBootKeyboard: Boolean;
  IsBootMouse: Boolean;
begin
  IsBootKeyboard := (Subclass = SubclassBoot) and (Protocol = ProtocolKeyboard);
  IsBootMouse := (Subclass = SubclassBoot) and (Protocol = ProtocolMouse);
  if IsBootKeyboard then
  begin
    if Parsed and Description.HasKeyboard and Description.HasPointer and Description.UsesReportIds then
      Exit(HidModeReports);
    Exit(HidModeBootKeyboard);
  end;
  if Parsed and (Description.HasPointer or Description.HasKeyboard) then
    Exit(HidModeReports);
  if IsBootMouse then
    Exit(HidModeBootMouse);
  Result := HidModeNone;
end;

end.
